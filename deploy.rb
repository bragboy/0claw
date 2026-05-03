#!/usr/bin/env ruby
# deploy.rb - multi-tenant 0claw deploy driver.
#
# Each tenant gets their own Docker container, Telegram bot, persona, and
# persistent storage under tenants/<slug>/. The image itself is shared.
#
# Usage:
#   ruby deploy.rb help                       show this help
#   ruby deploy.rb list                       list tenants on the VM with status
#   ruby deploy.rb spawn <slug>               scaffold a new tenant locally
#   ruby deploy.rb deploy <slug>              git pull + rebuild + redeploy this tenant
#   ruby deploy.rb deploy-all                 redeploy every tenant on the VM
#   ruby deploy.rb status [<slug>]            docker ps + zeroclaw status (all if no slug)
#   ruby deploy.rb logs <slug>                tail this tenant's container logs (Ctrl-C exits)
#   ruby deploy.rb env-refresh <slug>         scp tenants/<slug>/.env to the VM and restart
#   ruby deploy.rb tunnel <slug>              SSH tunnel to this tenant's gateway port
#   ruby deploy.rb ssh                        shell into the repo dir on the VM
#   ruby deploy.rb destroy <slug>             stop + remove this tenant's container
#   ruby deploy.rb bootstrap                  first-time VM setup (clone repo)
#   ruby deploy.rb migrate-from-single <slug> one-time: convert legacy single-tenant
#                                             VM layout (config/, workspace/, .env at
#                                             repo root) into tenants/<slug>/ and
#                                             redeploy under the new compose project
#
# Environment flags:
#   ALLOW_DIRTY=1   allow deploy with uncommitted local changes

require 'fileutils'

REMOTE_HOST = 'deploy@francium.tech'
REMOTE_DIR  = '/home/deploy/0claw'
SERVICE     = 'zeroclaw-hub'
REPO_URL    = 'https://github.com/bragboy/0claw.git'

def run(*cmd)
  puts "$ #{cmd.join(' ')}"
  system(*cmd) or abort("FAILED: #{cmd.inspect}")
end

def run!(*cmd)
  system(*cmd)
end

def ssh(script)
  run('ssh', REMOTE_HOST, script)
end

def ssh!(script)
  system('ssh', REMOTE_HOST, script)
end

def project_for(slug)
  "zeroclaw-#{slug}"
end

def tenant_env_path(slug)
  "tenants/#{slug}/.env"
end

# Compose args common to every invocation. The path strings are valid both
# locally (when we cd into the repo) and on the VM (REMOTE_DIR is the cwd).
def compose_args(slug)
  "-p #{project_for(slug)} --env-file #{tenant_env_path(slug)} -f docker-compose.yml"
end

def require_slug!(slug)
  abort 'usage: ruby deploy.rb <command> <slug>' unless slug && !slug.empty?
end

def require_local_tenant!(slug)
  require_slug!(slug)
  return if File.exist?(tenant_env_path(slug))
  abort "tenants/#{slug}/.env missing locally; run `ruby deploy.rb spawn #{slug}` first"
end

def parse_env_var(env_path, key)
  return nil unless File.exist?(env_path)
  File.foreach(env_path) do |line|
    return $1 if line =~ /\A\s*#{Regexp.escape(key)}\s*=\s*(.+?)\s*\z/
  end
  nil
end

def local_dirty
  out = `git status --porcelain 2>/dev/null`.strip
  out.empty? ? nil : out
end

def preflight
  if (dirty = local_dirty)
    puts 'local working tree is dirty:'
    puts dirty.lines.first(10).join
    unless ENV['ALLOW_DIRTY']
      abort 'commit + push before deploying, or re-run with ALLOW_DIRTY=1'
    end
    puts '(ALLOW_DIRTY=1 set, continuing with unpushed changes)'
  end
  run!('git', 'fetch', 'origin', 'main', '--quiet')
  ahead = `git rev-list origin/main..HEAD --count 2>/dev/null`.strip.to_i
  abort "local is #{ahead} commit(s) ahead of origin/main -- push before deploying" if ahead > 0
end

def list_remote_slugs
  out = `ssh #{REMOTE_HOST} 'ls -1 #{REMOTE_DIR}/tenants 2>/dev/null'`
  out.split("\n").map(&:strip).reject { |s| s.empty? || s.start_with?('.') }
end

def list_local_slugs
  return [] unless Dir.exist?('tenants')
  Dir.children('tenants').reject { |d| d.start_with?('.') || !File.directory?("tenants/#{d}") }.sort
end

def deploy_tenant(slug)
  ssh("cd #{REMOTE_DIR} && docker compose #{compose_args(slug)} up -d --build")
  ssh("cd #{REMOTE_DIR} && docker compose #{compose_args(slug)} exec -T #{SERVICE} init-deepseek.sh")
  ssh("cd #{REMOTE_DIR} && docker compose #{compose_args(slug)} restart #{SERVICE}")
end

cmd  = ARGV[0]
slug = ARGV[1]

case cmd

when 'help', '-h', '--help', nil, ''
  puts File.read(__FILE__).lines.drop(1).take_while { |l| l.start_with?('#') }
                                .map { |l| l.sub(/^# ?/, '') }.join

when 'list'
  remote_slugs = list_remote_slugs
  if remote_slugs.empty?
    puts 'no tenants on the VM yet'
  else
    puts "tenants on VM: #{remote_slugs.join(', ')}"
    ssh("docker ps --filter name=zeroclaw-hub- --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'")
  end

when 'spawn'
  require_slug!(slug)
  abort 'slug must be lowercase letters/digits/dashes' unless slug =~ /\A[a-z0-9][a-z0-9-]*\z/
  abort "tenants/#{slug}/ already exists locally" if Dir.exist?("tenants/#{slug}")

  used_ports = list_local_slugs.map { |s| parse_env_var(tenant_env_path(s), 'ZEROCLAW_GATEWAY_PORT')&.to_i }.compact
  next_port  = ([42616, *used_ports].max) + 1

  FileUtils.mkdir_p "tenants/#{slug}/config/zeroclaw"
  FileUtils.mkdir_p "tenants/#{slug}/config/claude"
  FileUtils.mkdir_p "tenants/#{slug}/workspace"

  template = File.read('.env.example')
  filled = template.dup
  filled.sub!(/^USER_SLUG=.*/, "USER_SLUG=#{slug}")
  filled.sub!(/^ZEROCLAW_GATEWAY_PORT=.*/, "ZEROCLAW_GATEWAY_PORT=#{next_port}")
  File.write(tenant_env_path(slug), filled)
  File.chmod(0600, tenant_env_path(slug))

  puts <<~MSG
    scaffolded tenants/#{slug}/ (gateway port #{next_port})
    edit tenants/#{slug}/.env to fill in:
      DEEPSEEK_API_KEY  BRAVE_API_KEY  TELEGRAM_BOT_TOKEN
      TELEGRAM_ALLOWED_USER_ID  AGENT_NAME  USER_TIMEZONE  AUTONOMY_LEVEL
    then run: ruby deploy.rb deploy #{slug}
  MSG

when 'deploy'
  require_local_tenant!(slug)
  preflight
  ssh("cd #{REMOTE_DIR} && git pull --ff-only")

  remote_env_present = run!('ssh', REMOTE_HOST, "test -f #{REMOTE_DIR}/#{tenant_env_path(slug)}")
  unless remote_env_present
    puts "VM has no #{tenant_env_path(slug)} yet; copying local copy"
    ssh("mkdir -p #{REMOTE_DIR}/tenants/#{slug}/config/zeroclaw #{REMOTE_DIR}/tenants/#{slug}/config/claude #{REMOTE_DIR}/tenants/#{slug}/workspace")
    run('scp', tenant_env_path(slug), "#{REMOTE_HOST}:#{REMOTE_DIR}/#{tenant_env_path(slug)}")
    ssh("chmod 600 #{REMOTE_DIR}/#{tenant_env_path(slug)}")
  end

  deploy_tenant(slug)
  ssh("cd #{REMOTE_DIR} && docker compose #{compose_args(slug)} ps")

when 'deploy-all'
  preflight
  ssh("cd #{REMOTE_DIR} && git pull --ff-only")
  slugs = list_remote_slugs
  abort 'no tenants found on the VM' if slugs.empty?
  puts "deploying tenants: #{slugs.join(', ')}"
  slugs.each do |s|
    puts "--- #{s} ---"
    deploy_tenant(s)
  end
  ssh("docker ps --filter name=zeroclaw-hub- --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'")

when 'env-refresh'
  require_local_tenant!(slug)
  ssh("mkdir -p #{REMOTE_DIR}/tenants/#{slug}")
  run('scp', tenant_env_path(slug), "#{REMOTE_HOST}:#{REMOTE_DIR}/#{tenant_env_path(slug)}")
  ssh("chmod 600 #{REMOTE_DIR}/#{tenant_env_path(slug)}")
  ssh("cd #{REMOTE_DIR} && docker compose #{compose_args(slug)} up -d")
  ssh("cd #{REMOTE_DIR} && docker compose #{compose_args(slug)} exec -T #{SERVICE} init-deepseek.sh")
  ssh("cd #{REMOTE_DIR} && docker compose #{compose_args(slug)} restart #{SERVICE}")

when 'status'
  if slug
    ssh("cd #{REMOTE_DIR} && docker compose #{compose_args(slug)} ps")
    ssh("cd #{REMOTE_DIR} && docker compose #{compose_args(slug)} exec -T #{SERVICE} zeroclaw status 2>&1 | tail -30")
  else
    ssh("docker ps --filter name=zeroclaw-hub- --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'")
  end

when 'logs'
  require_local_tenant!(slug)
  exec('ssh', '-t', REMOTE_HOST, "cd #{REMOTE_DIR} && docker compose #{compose_args(slug)} logs -f --tail 100 #{SERVICE}")

when 'tunnel'
  require_local_tenant!(slug)
  port = parse_env_var(tenant_env_path(slug), 'ZEROCLAW_GATEWAY_PORT')&.to_i
  abort "ZEROCLAW_GATEWAY_PORT not set in #{tenant_env_path(slug)}" unless port
  puts "tunnel: localhost:#{port} -> #{REMOTE_HOST}:#{port}  (Ctrl-C to close)"
  puts "open http://localhost:#{port} in another terminal."
  exec('ssh', '-N', '-L', "#{port}:127.0.0.1:#{port}", REMOTE_HOST)

when 'ssh'
  exec('ssh', '-t', REMOTE_HOST, "cd #{REMOTE_DIR} && exec $SHELL -l")

when 'destroy'
  require_local_tenant!(slug)
  print "tear down #{slug}'s container? state in tenants/#{slug}/ will remain on the VM. [y/N] "
  ans = STDIN.gets&.strip&.downcase
  abort 'aborted' unless ans == 'y'
  ssh("cd #{REMOTE_DIR} && docker compose #{compose_args(slug)} down")

when 'bootstrap'
  abort 'usage: ruby deploy.rb bootstrap <slug> -- spawn the tenant locally first' unless slug
  require_local_tenant!(slug)
  ssh("test -d #{REMOTE_DIR} && echo 'repo already cloned' || git clone #{REPO_URL} #{REMOTE_DIR}")
  ssh("cd #{REMOTE_DIR} && git fetch --all && git checkout main && git pull --ff-only")
  ssh("mkdir -p #{REMOTE_DIR}/tenants/#{slug}/config/zeroclaw #{REMOTE_DIR}/tenants/#{slug}/config/claude #{REMOTE_DIR}/tenants/#{slug}/workspace")

  remote_env_present = run!('ssh', REMOTE_HOST, "test -f #{REMOTE_DIR}/#{tenant_env_path(slug)}")
  if remote_env_present
    puts "remote tenants/#{slug}/.env already exists, not overwriting (use env-refresh to replace)"
  else
    run('scp', tenant_env_path(slug), "#{REMOTE_HOST}:#{REMOTE_DIR}/#{tenant_env_path(slug)}")
    ssh("chmod 600 #{REMOTE_DIR}/#{tenant_env_path(slug)}")
  end

  deploy_tenant(slug)
  ssh("cd #{REMOTE_DIR} && docker compose #{compose_args(slug)} ps")

when 'migrate-from-single'
  require_local_tenant!(slug)
  port = parse_env_var(tenant_env_path(slug), 'ZEROCLAW_GATEWAY_PORT')&.to_i || 42617
  preflight
  ssh("cd #{REMOTE_DIR} && git pull --ff-only")

  # Stop legacy container, move state into tenants/<slug>/, ensure USER_SLUG
  # and ZEROCLAW_GATEWAY_PORT are present in the migrated .env.
  migrate_script = <<~SH
    set -e
    cd #{REMOTE_DIR}

    if docker ps -a --format '{{.Names}}' | grep -q '^zeroclaw-hub$'; then
      echo 'stopping legacy zeroclaw-hub container'
      docker stop zeroclaw-hub
      docker rm zeroclaw-hub
    fi

    mkdir -p tenants/#{slug}/config
    if [ -d config/zeroclaw ]; then mv config/zeroclaw tenants/#{slug}/config/; fi
    if [ -d config/claude ];   then mv config/claude   tenants/#{slug}/config/; fi
    if [ -d workspace ];       then mv workspace       tenants/#{slug}/workspace; fi
    if [ -f .env ];            then mv .env            tenants/#{slug}/.env; fi
    rmdir config 2>/dev/null || true

    if [ -f tenants/#{slug}/.env ]; then
      if ! grep -q '^USER_SLUG='            tenants/#{slug}/.env; then echo USER_SLUG=#{slug}            >> tenants/#{slug}/.env; fi
      if ! grep -q '^ZEROCLAW_GATEWAY_PORT=' tenants/#{slug}/.env; then echo ZEROCLAW_GATEWAY_PORT=#{port} >> tenants/#{slug}/.env; fi
      chmod 600 tenants/#{slug}/.env
    fi
    echo 'state migration complete'
  SH
  ssh(migrate_script)

  # Bring the tenant up under the new compose project name.
  deploy_tenant(slug)
  ssh("cd #{REMOTE_DIR} && docker compose #{compose_args(slug)} ps")

else
  warn "unknown command: #{cmd.inspect}"
  warn 'try: ruby deploy.rb help'
  exit 1
end
