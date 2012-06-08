# Copyright (c) 2009-2011 VMware, Inc.
require "resque-status"
require "fileutils"
require "vcap/logging"
require "uuid"

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '..')
require "service_error"

module VCAP::Services::Base::AsyncJob
  module Snapshot
    include VCAP::Services::Base::Error

    SNAPSHOT_KEY_PREFIX = "vcap:snapshot".freeze
    SNAPSHOT_ID = "maxid".freeze
    FILTER_KEYS = %w(snapshot_id date size).freeze

    class << self
      attr_reader :redis

      def redis_connect
        @redis = ::Redis.new(Config.redis_config)

        redis_init
      end

      # initialize necessary keys
      def redis_init
        @redis.setnx("#{SNAPSHOT_KEY_PREFIX}:#{SNAPSHOT_ID}", 1)
      end
    end

    def client
      Snapshot.redis
    end

    # Get all snapshots related to a service instance
    #
    def service_snapshots(service_id)
      return unless service_id
      res = client.hgetall(redis_key(service_id))
      res.values.map{|v| Yajl::Parser.parse(v)}
    end

    # Return total snapshots count
    #
    def service_snapshots_count(service_id)
      return unless service_id
      client.hlen(redis_key(service_id))
    end

    # Get detail information for a single snapshot
    #
    def snapshot_details(service_id, snapshot_id)
      return unless service_id && snapshot_id
      res = client.hget(redis_key(service_id), snapshot_id)
      raise ServiceError.new(ServiceError::NOT_FOUND, "snapshot #{snapshot_id}") unless res
      Yajl::Parser.parse(res)
    end

    # filter internal keys of a given snapshot object, return a new snapshot object in canonical format
    def filter_keys(snapshot)
      return unless snapshot.is_a? Hash
      snapshot.select {|k,v| FILTER_KEYS.include? k.to_s}
    end

    # Generate a new unique id for a snapshot
    def new_snapshot_id
      client.incr(redis_key(SNAPSHOT_ID)).to_s
    end

    # Get the snapshot file path that service should save the dump file to.
    # the snapshot path structure looks like <base_dir>\snapshots\<service-name>\<aa>\<bb>\<cc>\<aabbcc-rest-of-instance-guid>\snapshot_id\<service specific data>
    def snapshot_filepath(base_dir, service_name, service_id, snapshot_id)
      File.join(base_dir, "snapshots", service_name, service_id[0,2], service_id[2,2], service_id[4,2], service_id, snapshot_id.to_s)
    end

    def save_snapshot(service_id , snapshot)
      return unless service_id && snapshot
      sid = snapshot[:snapshot_id] || snapshot["snapshot_id"]
      msg = Yajl::Encoder.encode(snapshot)
      client.hset(redis_key(service_id), sid, msg)
    end

    def delete_snapshot(service_id , snapshot_id)
      return unless service_id && snapshot_id
      client.hdel(redis_key(name), snapshot_id)
    end


    def fmt_time()
      # UTC time in ISO 8601 format.
      Time.now.utc.strftime("%FT%TZ")
    end

    protected

    def redis_key(key)
      "#{SNAPSHOT_KEY_PREFIX}:#{key}"
    end

    # common utils for snapshot job
    class SnapshotJob
      attr_reader :name, :snapshot_id

      include Snapshot
      include Resque::Plugins::Status

      class << self
        def queue_lookup_key
          :node_id
        end

        def select_queue(*args)
          result = nil
          args.each do |arg|
            result = arg[queue_lookup_key]if (arg.is_a? Hash)&& (arg.has_key?(queue_lookup_key))
          end
          @logger = Config.logger
          @logger.info("Select queue #{result} for job #{self.class} with args:#{args.inspect}") if @logger
          result
        end
      end

      def initialize(*args)
        super(*args)
        parse_config
        init_worker_logger
        Snapshot.redis_connect
      end

      def fmt_error(e)
        "#{e}: [#{e.backtrace.join(" | ")}]"
      end

      def init_worker_logger
        @logger = Config.logger
      end

      def required_options(*args)
        missing_opts = args.select{|arg| !options.has_key? arg.to_s}
        raise ArgumentError, "Missing #{missing_opts.join(', ')} in options: #{options.inspect}" unless missing_opts.empty?
      end

      def create_lock
        lock_name = "lock:lifecycle:#{name}"
        ttl = @config[:job_ttl] || 600
        lock = Lock.new(lock_name, :logger => @logger, :ttl => ttl)
        lock
      end

      def get_dump_path(name, snapshot_id)
        snapshot_filepath(@config["snapshots_base_dir"], @config["service_name"], name, snapshot_id)
      end

      def parse_config
        @config = Yajl::Parser.parse(ENV['WORKER_CONFIG'])
        raise "Need environment variable: WORKER_CONFIG" unless @config
      end

      def cleanup(name, snapshot_id)
        return unless name && snapshot_id
        @logger.info("Clean up snapshot and files for #{name}, snapshot id: #{snapshot_id}")
        delete_snapshot(name, snapshot_id)
        FileUtils.rm_rf(get_dump_path(name, snapshot_id))
      end

      def handle_error(e)
        @logger.error("Error in #{self.class} uuid:#{@uuid}: #{fmt_error(e)}")
        err = (e.instance_of?(ServiceError)? e : ServiceError.new(ServiceError::INTERNAL_ERROR)).to_hash
        err_msg = Yajl::Encoder.encode(err["msg"])
        failed(err_msg)
      end
    end

    class BaseCreateSnapshotJob < SnapshotJob
      # workflow template
      # Sub class should implement execute method which returns hash represents of snapshot like:
      # {:snapshot_id => 1, :size => 100, :file_name => "my_snapshot.tgz"}
      def perform
        begin
          required_options :service_id
          @name = options["service_id"]
          @logger.info("Launch job: #{self.class} for #{name}")

          @snapshot_id = new_snapshot_id
          lock = create_lock

          lock.lock do
            quota = @config["snapshot_quota"]
            if quota
              current = service_snapshots_count(name)
              @logger.debug("Current snapshots count for #{name}: #{current}, max: #{quota}")
              raise ServiceError.new(ServiceError::OVER_QUOTA, name, current, quota) if current >= quota
            end

            snapshot = execute
            @logger.info("Results of create snapshot: #{snapshot.inspect}")

            snapshot[:date] = fmt_time
            save_snapshot(name, snapshot)

            completed(Yajl::Encoder.encode(filter_keys(snapshot)))
            @logger.info("Complete job: #{self.class} for #{name}")
          end
        rescue => e
          cleanup(name, snapshot_id)
          handle_error(e)
        ensure
          set_status({:complete_time => Time.now.to_s})
        end
      end
    end

    class BaseDeleteSnapshotJob < SnapshotJob
      def perform
        begin
          required_options :service_id, :snapshot_id
          @name = options["service_id"]
          @snapshot_id = options["snapshot_id"]
          @logger.info("Launch job: #{self.class} for #{name}")

          lock = create_lock

          lock.lock do
            result = execute
            @logger.info("Results of delete snapshot: #{result}")

            delete_snapshot(name, snapshot_id)

            completed(Yajl::Encoder.encode({:result => :ok}))
            @logger.info("Complete job: #{self.class} for #{name}")
          end
        rescue => e
          handle_error(e)
        ensure
          set_status({:complete_time => Time.now.to_s})
        end
      end

      def execute
        cleanup(name, snapshot_id)
      end
    end

    class BaseRollbackSnapshotJob < SnapshotJob
      # workflow template
      # Subclass implement execute method which returns true for a successful rollback
      def perform
        begin
          required_options :service_id, :snapshot_id
          @name = options["service_id"]
          @snapshot_id = options["snapshot_id"]
          @logger.info("Launch job: #{self.class} for #{name}")

          lock = create_lock

          lock.lock do
            result = execute
            @logger.info("Results of rollback snapshot: #{result}")

            completed(Yajl::Encoder.encode({:result => :ok}))
            @logger.info("Complete job: #{self.class} for #{name}")
          end
        rescue => e
          handle_error(e)
        ensure
          set_status({:complete_time => Time.now.to_s})
        end
      end
    end
  end
end
