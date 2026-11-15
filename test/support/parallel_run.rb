require "etc"

# Runs the tests in forked worker processes, one per CPU core unless TEST_WORKERS says otherwise.
# TEST_WORKERS=1 runs everything in the one process, as Minitest normally does.
#
# The test files get loaded once, in the parent. Every worker then walks the same shuffled
# list of tests (they all seed the PRNG with the seed of the run) and runs every Nth one, sending
# the results to the parent, which feeds them to the reporters. Tests declared with
# `parallel: false` are left for one more worker, which runs after all the others are done. The `--name`, `--exclude`
# and `--seed` options work as usual, since the workers go through Minitest's own run.
module ParallelRun
  def self.worker_count
    @worker_count ||= begin
      from_env = ENV["TEST_WORKERS"].to_i
      count = (from_env > 0) ? from_env : Etc.nprocessors
      Process.respond_to?(:fork) ? count : 1
    end
  end

  class << self
    attr_accessor :worker_index, :tests_seen
  end

  # Stands in for the reporter inside of a worker
  class ResultPipe
    def initialize(io)
      @io = io
    end

    def prerecord(_klass, _method_name)
    end

    def record(result)
      Marshal.dump(result, @io)
    rescue TypeError => e
      # Something in the failures can't cross the process boundary
      failure = Minitest::UnexpectedError.new(RuntimeError.new("#{e.message}: #{result.failures.map(&:message).join("\n")}"))
      result.failures.replace([failure])
      Marshal.dump(result, @io)
    end
  end

  # Is only there to give ProgressReporter#prerecord something with a name in verbose mode
  NamedSuite = Struct.new(:name)

  module TakeEveryNth
    def run_one_method(klass, method_name, reporter)
      return super if ParallelRun.worker_index.nil?

      serial = klass.respond_to?(:serial_test?) && klass.serial_test?(method_name)
      return (super if serial) if ParallelRun.worker_index == :serial
      return if serial

      index = ParallelRun.tests_seen
      ParallelRun.tests_seen += 1
      super if index % ParallelRun.worker_count == ParallelRun.worker_index
    end
  end

  module ForkWorkers
    def __run(reporter, options)
      return super if ParallelRun.worker_count < 2

      $stdout.flush
      $stderr.flush
      start_worker = lambda do |index|
        reader, writer = IO.pipe
        reader.binmode
        writer.binmode
        pid = fork do
          reader.close
          # The PRNG gets reseeded in a forked process, and every worker has to shuffle the same way
          srand(options[:seed])
          ParallelRun.work(index) { super(ResultPipe.new(writer), options) }
        end
        writer.close
        [pid, reader]
      end

      record_lock = Mutex.new
      finish = lambda do |workers|
        workers.map { |_pid, reader|
          Thread.new do
            until reader.eof?
              result = Marshal.load(reader)
              record_lock.synchronize do
                reporter.prerecord(NamedSuite.new(result.klass), result.name)
                reporter.record(result)
              end
            end
          end
        }.each(&:join)
        workers.reject { |pid, _reader| Process.wait2(pid).last.success? }
      end

      crashed = finish.call(Array.new(ParallelRun.worker_count, &start_worker))
      # Tests declared with `parallel: false` run once the machine is quiet again
      crashed += finish.call([start_worker.call(:serial)])
      raise "#{crashed.length} test workers did not finish, the results are incomplete" if crashed.any?
      []
    end
  end

  def self.work(index)
    self.worker_index = index
    self.tests_seen = 0
    yield
    # exit! skips the at_exit hooks (or minitest/autorun would run everything once more),
    # so the after_run blocks registered in this worker have to be called here
    Minitest.class_variable_get(:@@after_run).reverse_each(&:call)
    $stdout.flush
    exit!(0)
  rescue Exception => e # rubocop:disable Lint/RescueException
    warn "Test worker #{index} crashed: #{e.class}: #{e.message}\n#{Array(e.backtrace).first(10).join("\n")}"
    exit!(1)
  end
end

Minitest.singleton_class.prepend(ParallelRun::ForkWorkers)
Minitest::Runnable.singleton_class.prepend(ParallelRun::TakeEveryNth)
