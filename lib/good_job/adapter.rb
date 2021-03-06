module GoodJob
  #
  # ActiveJob Adapter.
  #
  class Adapter
    # Valid execution modes.
    EXECUTION_MODES = [:async, :external, :inline].freeze

    # @param execution_mode [nil, Symbol] specifies how and where jobs should be executed. You can also set this with the environment variable +GOOD_JOB_EXECUTION_MODE+.
    #
    #  - +:inline+ executes jobs immediately in whatever process queued them (usually the web server process). This should only be used in test and development environments.
    #  - +:external+ causes the adapter to enqueue jobs, but not execute them. When using this option (the default for production environments), you'll need to use the command-line tool to actually execute your jobs.
    #  - +:async+ causes the adapter to execute you jobs in separate threads in whatever process queued them (usually the web process). This is akin to running the command-line tool's code inside your web server. It can be more economical for small workloads (you don't need a separate machine or environment for running your jobs), but if your web server is under heavy load or your jobs require a lot of resources, you should choose `:external` instead.
    #
    #  The default value depends on the Rails environment:
    #
    #  - +development+ and +test+: +:inline+
    #  - +production+ and all other environments: +:external+
    #
    # @param max_threads [nil, Integer] sets the number of threads per scheduler to use when +execution_mode+ is set to +:async+. The +queues+ parameter can specify a number of threads for each group of queues which will override this value. You can also set this with the environment variable +GOOD_JOB_MAX_THREADS+. Defaults to +5+.
    # @param queues [nil, String] determines which queues to execute jobs from when +execution_mode+ is set to +:async+. See {file:README.md#optimize-queues-threads-and-processes} for more details on the format of this string. You can also set this with the environment variable +GOOD_JOB_QUEUES+. Defaults to +"*"+.
    # @param poll_interval [nil, Integer] sets the number of seconds between polls for jobs when +execution_mode+ is set to +:async+. You can also set this with the environment variable +GOOD_JOB_POLL_INTERVAL+. Defaults to +1+.
    def initialize(execution_mode: nil, queues: nil, max_threads: nil, poll_interval: nil)
      if caller[0..4].find { |c| c.include?("/config/application.rb") || c.include?("/config/environments/") }
        ActiveSupport::Deprecation.warn(<<~DEPRECATION)
          GoodJob no longer recommends creating a GoodJob::Adapter instance:

              config.active_job.queue_adapter = GoodJob::Adapter.new...

          Instead, configure GoodJob through configuration:

              config.active_job.queue_adapter = :good_job
              config.good_job.execution_mode = :#{execution_mode}
              config.good_job.max_threads = #{max_threads}
              config.good_job.poll_interval = #{poll_interval}
              # etc...

        DEPRECATION
      end

      configuration = GoodJob::Configuration.new(
        {
          execution_mode: execution_mode,
          queues: queues,
          max_threads: max_threads,
          poll_interval: poll_interval,
        }
      )

      @execution_mode = configuration.execution_mode
      raise ArgumentError, "execution_mode: must be one of #{EXECUTION_MODES.join(', ')}." unless EXECUTION_MODES.include?(@execution_mode)

      if execute_async? # rubocop:disable Style/GuardClause
        @notifier = GoodJob::Notifier.new
        @poller = GoodJob::Poller.new(poll_interval: configuration.poll_interval)
        @scheduler = GoodJob::Scheduler.from_configuration(configuration, warm_cache_on_initialize: Rails.application.initialized?)
        @notifier.recipients << [@scheduler, :create_thread]
        @poller.recipients << [@scheduler, :create_thread]
      end
    end

    # Enqueues the ActiveJob job to be performed.
    # For use by Rails; you should generally not call this directly.
    # @param active_job [ActiveJob::Base] the job to be enqueued from +#perform_later+
    # @return [GoodJob::Job]
    def enqueue(active_job)
      enqueue_at(active_job, nil)
    end

    # Enqueues an ActiveJob job to be run at a specific time.
    # For use by Rails; you should generally not call this directly.
    # @param active_job [ActiveJob::Base] the job to be enqueued from +#perform_later+
    # @param timestamp [Integer] the epoch time to perform the job
    # @return [GoodJob::Job]
    def enqueue_at(active_job, timestamp)
      good_job = GoodJob::Job.enqueue(
        active_job,
        scheduled_at: timestamp ? Time.zone.at(timestamp) : nil,
        create_with_advisory_lock: execute_inline?
      )

      if execute_inline?
        begin
          good_job.perform
        ensure
          good_job.advisory_unlock
        end
      else
        job_state = { queue_name: good_job.queue_name }
        job_state[:scheduled_at] = good_job.scheduled_at if good_job.scheduled_at

        executed_locally = execute_async? && @scheduler.create_thread(job_state)
        Notifier.notify(job_state) unless executed_locally
      end

      good_job
    end

    # Gracefully stop processing jobs.
    # Waits for termination by default.
    # @param wait [Boolean] Whether to wait for shut down.
    # @return [void]
    def shutdown(wait: true)
      @notifier&.shutdown(wait: wait)
      @poller&.shutdown(wait: wait)
      @scheduler&.shutdown(wait: wait)
    end

    # Whether in +:async+ execution mode.
    def execute_async?
      @execution_mode == :async
    end

    # Whether in +:external+ execution mode.
    def execute_externally?
      @execution_mode == :external
    end

    # Whether in +:inline+ execution mode.
    def execute_inline?
      @execution_mode == :inline
    end
  end
end
