# -*- encoding : utf-8 -*-

# Sidekiq extension to track job execution statuses and returning job results back to the client in a convenient manner
module SidekiqStatus
  # SidekiqStatus job container. Contains all job attributes, redis storage/retrieval logic,
  # some syntactical sugar, such as status predicates and some attribute writers
  # Doesn't hook into Sidekiq worker
  class Container
    # Exception raised if SidekiqStatus job being loaded is not found in Redis
    class StatusNotFound < RuntimeError; end

    # Possible SidekiqStatus job statuses
    STATUS_NAMES = %w(waiting working complete failed killed).freeze

    # A list of statuses jobs in which are not considered pending
    FINISHED_STATUS_NAMES = %w(complete failed killed).freeze

    # Redis SortedSet key containing requests to kill {SidekiqStatus} jobs
    KILL_KEY = 'sidekiq_status_kill'.freeze

   # Redis SortedSet key to track existing {SidekiqStatus} jobs
    STATUSES_KEY = 'sidekiq_statuses'.freeze

    class_attribute :ttl
    self.ttl = 60*60*24*30 # 30 days

    # Default attribute values (assigned to a newly created container if not explicitly defined)
    DEFAULTS = {
        'args'    => [],
        'status'  => 'waiting',
        'at'      => 0,
        'total'   => 100,
        'message' => nil,
        'payload' => {}
    }.freeze

    attr_reader :uuid
    attr_reader :args, :status, :at, :total, :message, :last_updated_at
    attr_accessor :payload

    # @param [#to_s] uuid SidekiqStatus job id
    # @return [String] redis key to store/fetch {SidekiqStatus::Container} for the given job
    def self.status_key(uuid)
      "sidekiq_status:#{uuid}"
    end

    # @return [String] Redis SortedSet key to track existing {SidekiqStatus} jobs
    def self.statuses_key
      STATUSES_KEY
    end

    # @return [String] Redis SortedSet key containing requests to kill {SidekiqStatus} jobs
    def self.kill_key
      KILL_KEY
    end

    # Delete all {SidekiqStatus} jobs which are in given status
    #
    # @param [String,Array<String>,nil] status_names List of status names. If nil - delete jobs in any status
    def self.delete(status_names = nil)
      status_names ||= STATUS_NAMES
      status_names = [status_names] unless status_names.is_a?(Array)

      self.statuses.select{ |container| status_names.include?(container.status) }.map(&:delete)
    end


    # Retrieve {SidekiqStatus} job identifiers
    # It's possible to perform some pagination by specifying range boundaries
    #
    # @param [Integer] start
    # @param [Integer] stop
    # @return [Array<[String,uuid]>] Array of hash-like arrays of job id => last_updated_at (unixtime) pairs
    # @see *Redis#zrange* for details on return values format
    def self.status_uuids(start = 0, stop = -1)
      Sidekiq.redis do |conn|
        conn.zrange(self.statuses_key, start, stop, :with_scores => true)
      end
    end

    # Retrieve {SidekiqStatus} jobs
    # It's possible to perform some pagination by specifying range boundaries
    #
    # @param [Integer] start
    # @param [Integer] stop
    # @return [Array<SidekiqStatus::Container>]
    def self.statuses(start = 0, stop = -1)
      uuids = status_uuids(start, stop)
      uuids = Hash[uuids].keys
      load_multi(uuids)
    end

    # @return [Integer] Known {SidekiqStatus} jobs amount
    def self.size
      Sidekiq.redis do |conn|
        conn.zcard(self.statuses_key)
      end
    end

    # Create (initialize, generate unique uuid and save) a new {SidekiqStatus} job with given arguments.
    #
    # @param [*Object] args Job arguments
    # @return [SidekiqStatus::Container]
    def self.create(*args)
      new(SecureRandom.uuid, 'args' => args).tap(&:save)
    end

    # Load {SidekiqStatus::Container} by job identifier
    #
    # @param [String] uuid job identifier
    # @raise [StatusNotFound] if there's no info about {SidekiqStatus} job with given *uuid*
    # @return [SidekiqStatus::Container]
    def self.load(uuid)
      data = load_data(uuid)
      new(uuid, data)
    end

    # Load a list of {SidekiqStatus::Container SidekiqStatus jobs} from Redis
    #
    # @param [Array<String>] uuids A list of job identifiers to load
    # @return [Array<SidekiqStatus::Container>>]
    def self.load_multi(uuids)
      data = load_data_multi(uuids)
      data.map do |uuid, data|
        new(uuid, data)
      end
    end

    # Load {SidekiqStatus::Container SidekiqStatus job} {SidekiqStatus::Container#dump serialized data} from Redis
    #
    # @param [String] uuid job identifier
    # @raise [StatusNotFound] if there's no info about {SidekiqStatus} job with given *uuid*
    # @return [Hash] Job container data (as parsed json, but container is not yet initialized)
    def self.load_data(uuid)
      load_data_multi([uuid])[uuid] or raise StatusNotFound.new(uuid.to_s)
    end

    # Load multiple {SidekiqStatus::Container SidekiqStatus job} {SidekiqStatus::Container#dump serialized data} from Redis
    #
    # As this method is the most frequently used one, it also contains expire job clean up logic
    #
    # @param [Array<#to_s>] uuids a list of job identifiers to load data for
    # @return [Hash{String => Hash}] A hash of job-id to deserialized data pairs
    def self.load_data_multi(uuids)
      keys = uuids.map{ |uuid| status_key(uuid) }

      return {} if keys.empty?

      threshold = Time.now - self.ttl

      data = Sidekiq.redis do |conn|
        conn.multi do
          conn.mget(*keys)

          conn.zremrangebyscore(kill_key, 0, threshold.to_i)     # Clean up expired unprocessed kill requests
          conn.zremrangebyscore(statuses_key, 0, threshold.to_i) # Clean up expired statuses from statuses sorted set
        end
      end

      data = data.first.map do |json|
        json ? Sidekiq.load_json(json) : nil
      end

      Hash[uuids.zip(data)]
    end

    # Initialize a new {SidekiqStatus::Container} with given unique job identifier and attribute data
    #
    # @param [String] uuid
    # @param [Hash] data
    def initialize(uuid, data = {})
      @uuid = uuid
      load(data)
    end

    # Reload current container data from JSON (in case they've changed)
    def reload
      data = self.class.load_data(uuid)
      load(data)
      self
    end

    # @return [String] redis key to store current {SidekiqStatus::Container container}
    #   {SidekiqStatus::Container#dump data}
    def status_key
      self.class.status_key(uuid)
    end

    # Save current container attribute values to redis
    def save
      data = dump
      data = Sidekiq.dump_json(data)

      Sidekiq.redis do |conn|
        conn.multi do
          conn.setex(status_key, self.ttl, data)
          conn.zadd(self.class.statuses_key, Time.now.to_f.to_s, self.uuid)
        end
      end
    end

    # Delete current container data from redis
    def delete
      Sidekiq.redis do |conn|
        conn.multi do
          conn.del(status_key)

          conn.zrem(self.class.kill_key, self.uuid)
          conn.zrem(self.class.statuses_key, self.uuid)
        end
      end
    end

    # Request kill for the {SidekiqStatus::Worker SidekiqStatus job}
    # which parameters are tracked by the current {SidekiqStatus::Container}
    def request_kill
      Sidekiq.redis do |conn|
        conn.zadd(self.class.kill_key, Time.now.to_f.to_s, self.uuid)
      end
    end

    # @return [Boolean] if job kill is requested
    def kill_requested?
      Sidekiq.redis do |conn|
        conn.zrank(self.class.kill_key, self.uuid)
      end
    end

    # Reflect the fact that a job has been killed in redis
    def kill
      self.status = 'killed'

      Sidekiq.redis do |conn|
        conn.multi do
          save
          conn.zrem(self.class.kill_key, self.uuid)
        end
      end
    end

    # @return [Boolean] can the current job be killed
    def killable?
      !kill_requested? && %w(waiting working).include?(self.status)
    end

    # @return [Integer] Job progress in percents (reported solely by {SidekiqStatus::Worker job})
    def pct_complete
      (at.to_f / total * 100).round
    end

    # @param [Fixnum] at Report the progress of a job which is tracked by the current {SidekiqStatus::Container}
    def at=(at)
      raise ArgumentError, "at=#{at.inspect} is not a scalar number" unless at.is_a?(Numeric)
      @at = at
      @total = @at if @total < @at
    end

    # Report the estimated upper limit of {SidekiqStatus::Container#at= job items}
    #
    # @param [Fixnum] total
    def total=(total)
      raise ArgumentError, "total=#{total.inspect} is not a scalar number" unless total.is_a?(Numeric)
      @total = total
    end

    # Report current job execution status
    #
    # @param [String] status Current job {SidekiqStatus::STATUS_NAMES status}
    def status=(status)
      raise ArgumentError, "invalid status #{status.inspect}" unless STATUS_NAMES.include?(status)
      @status = status
    end

    # Report side message for the client code
    #
    # @param [String] message
    def message=(message)
      @message = message && message.to_s
    end

    # Assign multiple values to {SidekiqStatus::Container} attributes at once
    #
    # @param [Hash{#to_s => #to_json}] attrs Attribute=>value pairs
    def attributes=(attrs = {})
      attrs.each do |attr_name, value|
        setter = "#{attr_name}="
        send(setter, value)
      end
    end

    # Assign multiple values to {SidekiqStatus::Container} attributes at once and save to redis
    # @param [Hash{#to_s => #to_json}] attrs Attribute=>value pairs
    def update_attributes(attrs = {})
      self.attributes = attrs
      save
    end

    STATUS_NAMES.each do |status_name|
      define_method("#{status_name}?") do
        status == status_name
      end
    end

    protected

    # Merge-in given data to the current container
    #
    # @private
    # @param [Hash] data
    def load(data)
      data                                  = DEFAULTS.merge(data)
      @args, @status, @at, @total, @message = data.values_at('args', 'status', 'at', 'total', 'message')
      @payload                              = data['payload']
      @last_updated_at                      = data['last_updated_at'] && Time.at(data['last_updated_at'].to_i)
    end

    # Dump current container attribute values to json-serializable hash
    #
    # @private
    # @return [Hash] Data for subsequent json-serialization
    def dump
      {
          'status'          => self.status,
          'at'              => self.at,
          'total'           => self.total,
          'message'         => self.message,
          'args'            => self.args,
          'payload'         => self.payload,
          'last_updated_at' => Time.now.to_i
      }
    end
  end
end
