#!/usr/bin/env ruby
# deploy.rb - deploy 0claw to the remote VM.
#
# Usage:
#   ruby deploy.rb               standard deploy (git pull + rebuild + restart)
#   ruby deploy.rb bootstrap     first-time setup: clone repo + copy .env once
#   ruby deploy.rb status        remote docker compose ps + zeroclaw status
#   ruby deploy.rb logs          tail the remote daemon log (Ctrl-C to exit)
#   ruby deploy.rb env-refresh   overwrite remote .env with local .env + restart
#   ruby deploy.rb down          stop the remote container
#   ruby deploy.rb ssh           drop into a remote shell inside the repo
#   ruby deploy.rb tunnel        open an SSH tunnel to the dashboard on :42617
#   ruby deploy.rb help          show this help
#
# Environment flags:
#   ALLOW_DIRTY=1                allow deploy even if local tree is dirty

REMOTE_HOST = 'deploy@francium.tech'
REMOTE_DIR  = '/home/deploy/0claw'
SERVICE     = 'zeroclaw-hub'
REPO_URL    = 'https://github.com/bragboy/0claw.git'
DASHBOARD_LOCAL_PORT  = 42617
DASHBOARD_REMOTE_PORT = 42617

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
  if ahead > 0
    abort "local is #{ahead} commit(s) ahead of origin/main -- push before deploying"
  end
end

cmd = ARGV[0] || 'deploy'

case cmd
when 'bootstrap'
  abort 'local .env missing -- create one from .env.example before bootstrap' unless File.exist?('.env')

  ssh("test -d #{REMOTE_DIR} && echo 'repo already cloned' || git clone #{REPO_URL} #{REMOTE_DIR}")
  ssh("cd #{REMOTE_DIR} && git fetch --all && git checkout main && git pull --ff-only")

  remote_has_env = run!('ssh', REMOTE_HOST, "test -f #{REMOTE_DIR}/.env")
  if remote_has_env
    puts 'remote .env already exists, not overwriting (use env-refresh to replace)'
  else
    puts 'copying local .env to remote (one time)...'
    run('scp', '.env', "#{REMOTE_HOST}:#{REMOTE_DIR}/.env")
    ssh("chmod 600 #{REMOTE_DIR}/.env")
  end

  puts '--- first bring-up (may take 5-15 minutes on a 1 vCPU box) ---'
  ssh("cd #{REMOTE_DIR} && docker compose up -d --build")
  ssh("cd #{REMOTE_DIR} && docker compose exec -T #{SERVICE} init-deepseek.sh")
  ssh("cd #{REMOTE_DIR} && docker compose restart #{SERVICE}")
  ssh("cd #{REMOTE_DIR} && docker compose ps")

when 'deploy', nil, ''
  preflight
  ssh("cd #{REMOTE_DIR} && git pull --ff-only")
  ssh("cd #{REMOTE_DIR} && docker compose up -d --build")
  ssh("cd #{REMOTE_DIR} && docker compose exec -T #{SERVICE} init-deepseek.sh")
  ssh("cd #{REMOTE_DIR} && docker compose restart #{SERVICE}")
  ssh("cd #{REMOTE_DIR} && docker compose ps")

when 'status'
  ssh("cd #{REMOTE_DIR} && docker compose ps")
  ssh("cd #{REMOTE_DIR} && docker compose exec -T #{SERVICE} zeroclaw status 2>&1 | tail -30")

when 'logs'
  exec('ssh', '-t', REMOTE_HOST, "cd #{REMOTE_DIR} && docker compose logs -f --tail 100 #{SERVICE}")

when 'env-refresh'
  abort 'local .env missing' unless File.exist?('.env')
  puts 'overwriting remote .env with local copy'
  run('scp', '.env', "#{REMOTE_HOST}:#{REMOTE_DIR}/.env")
  ssh("chmod 600 #{REMOTE_DIR}/.env")
  ssh("cd #{REMOTE_DIR} && docker compose up -d")
  ssh("cd #{REMOTE_DIR} && docker compose exec -T #{SERVICE} init-deepseek.sh")
  ssh("cd #{REMOTE_DIR} && docker compose restart #{SERVICE}")

when 'down'
  ssh("cd #{REMOTE_DIR} && docker compose down")

when 'ssh'
  exec('ssh', '-t', REMOTE_HOST, "cd #{REMOTE_DIR} && exec $SHELL -l")

when 'tunnel'
  puts "opening SSH tunnel: localhost:#{DASHBOARD_LOCAL_PORT} -> #{REMOTE_HOST}:#{DASHBOARD_REMOTE_PORT}"
  puts "browse http://localhost:#{DASHBOARD_LOCAL_PORT} in another terminal. Ctrl-C here to close the tunnel."
  exec('ssh', '-N', '-L', "#{DASHBOARD_LOCAL_PORT}:localhost:#{DASHBOARD_REMOTE_PORT}", REMOTE_HOST)

when 'help', '-h', '--help'
  puts File.read(__FILE__).lines.drop(1).take_while { |l| l.start_with?('#') }.map { |l| l.sub(/^# ?/, '') }.join

else
  warn "unknown command: #{cmd}"
  warn 'try: ruby deploy.rb help'
  exit 1
end
