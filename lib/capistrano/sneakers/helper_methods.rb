module Capistrano
  module Sneakers
    module HelperMethods
      def sneakers_each_process_with_index(reverse = false, &block)
        _pid_files = sneakers_pid_files
        _pid_files.reverse! if reverse
        _pid_files.each_with_index do |pid_file, idx|
          within release_path do
            yield(pid_file, idx)
          end
        end
      end

      def sneakers_pid_files
        sneakers_roles = Array(fetch(:sneakers_roles))
        sneakers_roles.select! { |role| host.roles.include?(role) }
        sneakers_roles.flat_map do |role|
          processes = fetch(:sneakers_processes)
          if processes == 1
            fetch(:sneakers_pid)
          else
            Array.new(processes) { |idx| fetch(:sneakers_pid).gsub(/\.pid$/, "-#{idx}.pid") }
          end
        end
      end

      def sneakers_pid_file_exists?(pid_file)
        test(*("[ -f #{pid_file} ]").split(' '))
      end

      def sneakers_process_exists?(pid_file)
        test(*("kill -0 $( cat #{pid_file} )").split(' '))
      end

      def quiet_sneakers(pid_file)
        execute :kill, "-USR1 `cat #{pid_file}`"
      end

      def stop_sneakers(pid_file)
        execute :kill, "-SIGTERM `cat #{pid_file}`"
      end

      def start_sneakers(pid_file, idx = 0)
        raw_workers = fetch(:sneakers_workers)
        workers =
          if raw_workers && !raw_workers.empty?
            raw_workers.compact.join(',')
          else
            nil
          end

        info "Starting the sneakers processes"

        if workers
          with rails_env: fetch(:sneakers_env), workers: workers do
            rake 'sneakers:run'
          end
        else
          with rails_env: fetch(:sneakers_env) do
            rake 'sneakers:run'
          end
        end
      end

      def sneakers_switch_user(role, &block)
        user = sneakers_user(role)
        if user == role.user
          block.call
        else
          as user do
            block.call
          end
        end
      end

      def sneakers_user(role)
        properties = role.properties
        properties.fetch(:sneakers_user) || fetch(:sneakers_user) || properties.fetch(:run_as) || role.user
      end
    end
  end
end

