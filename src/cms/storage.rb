require "json"
require "fileutils"

module Cms
  module Storage
    @lock = Mutex.new
    @data_dir = nil

    def self.data_dir
      if @data_dir.nil?
        d = ENV["DATA_DIR"]
        d = "./data" if d.nil? || d.empty?
        FileUtils.mkdir_p(d)
        @data_dir = File.expand_path(d)
      end
      @data_dir
    end

    def self.read_collection(filename)
      path = File.join(data_dir, filename)
      return [] unless File.exist?(path)
      begin
        data = JSON.parse(File.read(path, encoding: "UTF-8"))
      rescue JSON::ParserError
        raise "Data file corrupted: #{path}"
      end
      data.is_a?(Array) ? data : []
    end

    # Atomic write: serialize to a sibling temp file, then rename over the target.
    # A crash mid-write leaves the previous good file intact.
    def self.write_collection(filename, items)
      path = File.join(data_dir, filename)
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.pretty_generate(items))
      File.rename(tmp, path)
    end

    def self.with_lock
      @lock.synchronize { yield }
    end
  end
end
