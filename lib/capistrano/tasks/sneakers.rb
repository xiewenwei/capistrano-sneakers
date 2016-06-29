namespace :load do

  task :defaults do
    set :sneakers_default_hooks, -> { true }

    set :sneakers_pid, -> { File.join(shared_path, 'tmp', 'pids', 'sneakers.pid') }
    set :sneakers_env, -> { fetch(:rack_env, fetch(:rails_env, fetch(:stage))) }
    set :sneakers_log, -> { File.join(shared_path, 'log', 'sneakers.log') }
    # set :sneakers_timeout, -> { 10 }
    set :sneakers_role, -> { :app }
    set :sneakers_processes, -> { 1 }
    set :sneakers_workers, -> { false } # if this is false it will cause Capistrano to exit
    set :sneakers_run_config, -> { false } # if this is true sneakers will run with preconfigured /config/initializers/sneakers.rb
    set :sneakers_boot_file, -> { false } # Needed for booting daemons dynamically
    # Rbenv and RVM integration
    set :rbenv_map_bins, fetch(:rbenv_map_bins).to_a.concat(%w(sneakers))
    set :rvm_map_bins, fetch(:rvm_map_bins).to_a.concat(%w(sneakers))
  end
end


namespace :deploy do

  before :starting, :check_sneakers_hooks do
    invoke 'sneakers:add_default_hooks' if fetch(:sneakers_default_hooks)
  end

  after :publishing, :restart_sneakers do
    invoke 'sneakers:restart' if fetch(:sneakers_default_hooks)
  end
end

namespace :sneakers do

  def for_each_sneakers_process(reverse = false, &block)
    pids = processes_sneakers_pids
    pids.reverse! if reverse
    pids.each_with_index do |pid_file, idx|
      within current_path do
        yield(pid_file, idx)
      end
    end
  end

  def processes_sneakers_pids
    pids = []
    raise "sneaker_processes is nil class, cannot continue, please [set :sneaker_processes]" if fetch(:sneakers_processes).nil?
    fetch(:sneakers_processes).times do |idx|
      pids.push (idx.zero? && fetch(:sneakers_processes) <= 1) ?
                    fetch(:sneakers_pid) :
                    fetch(:sneakers_pid).gsub(/\.pid$/, "-#{idx}.pid")

    end
    pids
  end

  def sneakers_pid_process_exists?(pid_file)
    sneakers_pid_file_exists?(pid_file) and test(*("kill -0 $( cat #{pid_file} )").split(' '))
  end

  def sneakers_pid_file_exists?(pid_file)
    test(*("[ -f #{pid_file} ]").split(' '))
  end

  def stop_sneakers(pid_file)
    if fetch(:sneakers_run_config) == true
      execute "cd #{current_path} && kill -TERM `cat #{pid_file}`"
    else
      if fetch(:stop_sneakers_in_background, fetch(:sneakers_run_in_background))
        if fetch(:sneakers_use_signals)
          background "kill -TERM `cat #{pid_file}`"
        else
          background :bundle, :exec, :sneakersctl, 'stop', "#{pid_file}", fetch(:sneakers_timeout)
        end
      else
        execute :bundle, :exec, :sneakersctl, 'stop', "#{pid_file}", fetch(:sneakers_timeout)
      end
    end
  end

  def quiet_sneakers(pid_file)
    if fetch(:sneakers_use_signals) || fetch(:sneakers_run_config)
      background "cd #{current_path} && kill -USR1 `cat #{pid_file}`"
    else
      begin
        execute :bundle, :exec, :sneakersctl, 'quiet', "#{pid_file}"
      rescue SSHKit::Command::Failed
        # If gems are not installed eq(first deploy) and sneakers_default_hooks as active
        warn 'sneakersctl not found (ignore if this is the first deploy)'
      end
    end
  end

  def start_sneakers(pid_file, idx = 0)
    if fetch(:sneakers_run_config) == true
      # Use sneakers configuration prebuilt in
      #raise "[ set :workers, ['worker1', 'workerN'] ] not configured properly, please configure the workers you wish to use" if fetch(:sneakers_workers).nil? or fetch(:sneakers_workers) == false or !fetch(:sneakers_workers).kind_of? Array

      raw_workers = fetch(:sneakers_workers)
      workers =
        if raw_workers && !raw_workers.empty?
          raw_workers.compact.join(',')
        else
          nil
        end

      #run "cmd", env: { 'WORKERS' => workers } #export this to environmental variable
      info "Starting the sneakers processes"
      #workers.each do |worker|

      if workers
        with rails_env: fetch(:sneakers_env), workers: workers do
          rake 'sneakers:run'
        end
      else
        with rails_env: fetch(:sneakers_env) do
          rake 'sneakers:run'
        end
      end

      #execute :bundle, :exec, :sneakers, args.compact.join(' ')
    else
      # Using custom sneakers setup
      args.push "--index #{idx}"
      args.push "--pidfile #{pid_file}"
      args.push "--environment #{fetch(:sneakers_env)}"
      args.push "--logfile #{fetch(:sneakers_log)}" if fetch(:sneakers_log)
      args.push "--require #{fetch(:sneakers_require)}" if fetch(:sneakers_require)
      args.push "--tag #{fetch(:sneakers_tag)}" if fetch(:sneakers_tag)
      Array(fetch(:sneakers_queue)).each do |queue|
        args.push "--queue #{queue}"
      end
      args.push "--config #{fetch(:sneakers_config)}" if fetch(:sneakers_config)
      args.push "--concurrency #{fetch(:sneakers_concurrency)}" if fetch(:sneakers_concurrency)
      # use sneakers_options for special options
      args.push fetch(:sneakers_options) if fetch(:sneakers_options)

      if defined?(JRUBY_VERSION)
        args.push '>/dev/null 2>&1 &'
        warn 'Since JRuby doesn\'t support Process.daemon, sneakers will not be running as a daemon.'
      else
        args.push '--daemon'
      end

      if fetch(:start_sneakers_in_background, fetch(:sneakers_run_in_background))
        background :bundle, :exec, :sneakers, args.compact.join(' ')
      else
        execute :bundle, :exec, :sneakers, args.compact.join(' ')
      end
    end
  end

  task :add_default_hooks do
    # Disable sneakers:quiet when deploying to prevent process hung up.
    # Modified by vincent on 2015.11.9
    #after 'deploy:starting', 'sneakers:quiet'
    #after 'deploy:updated', 'sneakers:stop'
    #after 'deploy:reverted', 'sneakers:stop'
    #after 'deploy:published', 'sneakers:start'
  end

  desc 'Quiet sneakers (stop processing new tasks)'
  task :quiet do
    on roles fetch(:sneakers_role) do
      if test("[ -d #{current_path} ]") # fixes #11
        for_each_sneakers_process(true) do |pid_file, idx|
          if sneakers_pid_process_exists?(pid_file)
            quiet_sneakers(pid_file)
          end
        end
      end
    end
  end

  desc 'Stop sneakers'
  task :stop do
    on roles fetch(:sneakers_role) do
      if test("[ -d #{current_path} ]")
        for_each_sneakers_process(true) do |pid_file, idx|
          if sneakers_pid_process_exists?(pid_file)
            stop_sneakers(pid_file)
          end
        end
      end
    end
  end

  desc 'Start sneakers'
  task :start do
    on roles fetch(:sneakers_role) do
      for_each_sneakers_process do |pid_file, idx|
        start_sneakers(pid_file, idx) unless sneakers_pid_process_exists?(pid_file)
      end
    end
  end

  desc 'Restart sneakers'
  task :restart do
    on roles(:sneakers_server), in: :sequence  do
    if test("[ -d #{current_path} ]")
        for_each_sneakers_process(true) do |pid_file, idx|
          if sneakers_pid_process_exists?(pid_file)
            stop_sneakers(pid_file)
        end
      end
    end  
    sleep 1
    for_each_sneakers_process do |pid_file, idx|
        start_sneakers(pid_file, idx) unless sneakers_pid_process_exists?(pid_file)
     end
   end
 end

  desc 'Rolling-restart sneakers'
  task :rolling_restart do
    on roles fetch(:sneakers_role) do
      for_each_sneakers_process(true) do |pid_file, idx|
        if sneakers_pid_process_exists?(pid_file)
          stop_sneakers(pid_file)
        end
        start_sneakers(pid_file, idx)
      end
    end
  end

  # Delete any pid file not in use
  task :cleanup do
    on roles fetch(:sneakers_role) do
      for_each_sneakers_process do |pid_file, idx|
        if sneakers_pid_file_exists?(pid_file)
          execute "rm #{pid_file}" unless sneakers_pid_process_exists?(pid_file)
        end
      end
    end
  end

  # TODO : Don't start if all proccess are off, raise warning.
  desc 'Respawn missing sneakers proccesses'
  task :respawn do
    invoke 'sneakers:cleanup'
    on roles fetch(:sneakers_role) do
      for_each_sneakers_process do |pid_file, idx|
        unless sneakers_pid_file_exists?(pid_file)
          start_sneakers(pid_file, idx)
        end
      end
    end
  end

  def template_sneakers(from, to, role)
    [
        File.join('lib', 'capistrano', 'templates', "#{from}-#{role.hostname}-#{fetch(:stage)}.rb"),
        File.join('lib', 'capistrano', 'templates', "#{from}-#{role.hostname}.rb"),
        File.join('lib', 'capistrano', 'templates', "#{from}-#{fetch(:stage)}.rb"),
        File.join('lib', 'capistrano', 'templates', "#{from}.rb.erb"),
        File.join('lib', 'capistrano', 'templates', "#{from}.rb"),
        File.join('lib', 'capistrano', 'templates', "#{from}.erb"),
        File.expand_path("../../templates/#{from}.rb.erb", __FILE__),
        File.expand_path("../../templates/#{from}.erb", __FILE__)
    ].each do |path|
      if File.file?(path)
        erb = File.read(path)
        upload! StringIO.new(ERB.new(erb).result(binding)), to
        break
      end
    end
  end
end
