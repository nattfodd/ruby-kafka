module Kafka
  class OffsetManager
    def initialize(cluster:, group:, logger:, commit_interval:, commit_threshold:)
      @cluster = cluster
      @group = group
      @logger = logger
      @commit_interval = commit_interval
      @commit_threshold = commit_threshold

      @uncommitted_offsets = 0
      @processed_offsets = {}
      @default_offsets = {}
      @committed_offsets = nil
      @last_commit = Time.now
    end

    def set_default_offset(topic, default_offset)
      @default_offsets[topic] = default_offset
    end

    def mark_as_processed(topic, partition, offset)
      @uncommitted_offsets += 1
      @processed_offsets[topic] ||= {}
      @processed_offsets[topic][partition] = offset
      @logger.debug "Marking #{topic}/#{partition}:#{offset} as committed"
    end

    def next_offset_for(topic, partition)
      offset = @processed_offsets.fetch(topic, {}).fetch(partition) {
        committed_offset_for(topic, partition)
      }

      # A negative offset means that no offset has been committed, so we need to
      # resolve the default offset for the topic.
      if offset < 0
        default_offset = @default_offsets.fetch(topic)
        @cluster.resolve_offset(topic, partition, default_offset)
      else
        # The next offset is the last offset plus one.
        offset + 1
      end
    end

    def commit_offsets
      unless @processed_offsets.empty?
        pretty_offsets = @processed_offsets.flat_map {|topic, partitions|
          partitions.map {|partition, offset| "#{topic}/#{partition}:#{offset}" }
        }.join(", ")

        @logger.info "Committing offsets: #{pretty_offsets}"

        @group.commit_offsets(@processed_offsets)

        @last_commit = Time.now

        @uncommitted_offsets = 0
        @committed_offsets = nil
      end
    end

    def commit_offsets_if_necessary
      if seconds_since_last_commit >= @commit_interval || commit_threshold_reached?
        commit_offsets
      end
    end

    def clear_offsets
      @processed_offsets.clear

      # Clear the cached commits from the brokers.
      @committed_offsets = nil
    end

    def clear_offsets_excluding(excluded)
      # Clear all offsets that aren't in `excluded`.
      @processed_offsets.each do |topic, partitions|
        partitions.keep_if do |partition, _|
          excluded.fetch(topic, []).include?(partition)
        end
      end

      # Clear the cached commits from the brokers.
      @committed_offsets = nil
    end

    private

    def seconds_since_last_commit
      Time.now - @last_commit
    end

    def committed_offset_for(topic, partition)
      @committed_offsets ||= @group.fetch_offsets
      @committed_offsets.offset_for(topic, partition)
    end

    def commit_threshold_reached?
      @commit_threshold != 0 && @uncommitted_offsets >= @commit_threshold
    end
  end
end
