# frozen_string_literal: true

# Records the Prawn manual's examples as operation scripts
# (docs/op-scripts.md), so the manual becomes a corpus both implementations
# run and are compared on:
#
#   ruby scripts/oracle/record_manual.rb OUT_DIR
#
# Each example runs on a real Prawn document through a recorder that writes
# down the calls the example makes on the document: a call with a block
# becomes an op with a block of the calls made inside it, and a call whose
# value the example uses (the cursor, the bounds, a width) becomes a query,
# so both implementations log it. What Ruby computes around the calls (loops,
# string interpolation) is recorded as the values it produced. An example
# that hands Prawn something an op script cannot express (a proc, an object)
# is skipped, and the reason printed. The scripts are tests in their own
# right: replayed through the driver, they need not reproduce the manual's
# pages exactly.

ROOT = File.expand_path('../..', __dir__)
REPOS = File.join(ROOT, '.repos')
GEMS = File.join(REPOS, 'gems')
PRAWN_DIR = File.join(REPOS, 'prawn')
$LOAD_PATH.unshift(File.join(PRAWN_DIR, 'lib'))
%w[pdf-core-0.10.0 ttfunk-1.8.0].each { |g| $LOAD_PATH.unshift(File.join(GEMS, g, 'lib')) }

require 'json'
require 'fileutils'
require 'prawn'

# What cannot be written as an op script.
class Unrecordable < StandardError; end

# The manual's chapter DSL, keeping only the examples.
module Prawn
  module ManualBuilder
    # where the manual's examples find their fonts and images
    DATADIR = File.join(PRAWN_DIR, 'data')

    # A chapter: its title and its examples' options and blocks.
    class Chapter
      class << self
        attr_accessor :last
      end

      attr_reader :examples

      def initialize(&block)
        @examples = []
        instance_eval(&block)
        Chapter.last = self
      end

      def title(*); end

      def text(*); end

      def example(**options, &block)
        @examples << [options, block]
      end
    end
  end
end

module Kernel
  alias recorder_original_require require

  def require(name)
    name == 'prawn/manual_builder' ? true : recorder_original_require(name)
  end
  private :require
end

# Calls whose value is an observation: recorded as queries.
QUERIES = %i[
  cursor bounds width_of height_of height_of_formatted page_number page_count y
  font_size text_box formatted_text_box
].freeze

# Calls that are about the recorder, never recorded.
IGNORED = %i[respond_to? respond_to_missing? is_a? class inspect to_s].freeze

# Op-script values.
module OpValues; end

# Converts a Ruby value to an op-script value.
def OpValues.json(value)
  case value
  when Symbol then ":#{value}"
  when String
    if value.start_with?("#{PRAWN_DIR}/")
      "$PRAWN/#{value.delete_prefix("#{PRAWN_DIR}/")}"
    elsif value.start_with?(':')
      ":#{value}"
    else
      value
    end
  when Integer, Float, true, false, nil then value
  when Array then value.map { |v| OpValues.json(v) }
  when Hash
    value.to_h do |k, v|
      raise Unrecordable, "a hash keyed by #{k.class}" unless k.is_a?(Symbol) || k.is_a?(String)

      key = k.is_a?(Symbol) ? k.to_s : "=#{k}"
      [key, OpValues.json(v)]
    end
  when Range then raise Unrecordable, 'a range'
  else raise Unrecordable, "a #{value.class}"
  end
end

# Stands in for the document while an example runs, recording its calls.
class Recorder < BasicObject
  def initialize(doc)
    @doc = doc
    @lists = [[]]
    @closed = {}
  end

  def recorded
    @lists.first
  end

  def method_missing(name, *args, **options, &block)
    return @doc.__send__(name, *args, **options, &block) if ::IGNORED.include?(name)
    # Ruby's own functions (Integer, require) are not the document's
    unless @doc.respond_to?(name)
      return ::Kernel.instance_method(name).bind_call(self, *args, **options, &block)
    end
    # `font_families.update(…)`: recorded as that dotted call
    return ::FamiliesRecorder.new(@doc.font_families, @lists.last) if name == :font_families && args.empty?


    op = [::QUERIES.include?(name) ? "?#{name}" : name.to_s, *args.map { |a| ::OpValues.json(a) }]
    trailing = options.empty? ? nil : ::OpValues.json(options)
    list = @lists.last
    ::Kernel.raise ::Unrecordable, "#{name} called after its block's op was recorded" if @closed[list.object_id]

    if block
      inner = []
      trailing = (trailing || {}).merge('block' => inner)
      op << trailing
      list << op
      wrapped = ::Kernel.proc do |*block_args|
        ::Kernel.raise ::Unrecordable, "#{name} yields arguments" unless block_args.empty?
        ::Kernel.raise ::Unrecordable, "#{name} runs its block later" if @closed[inner.object_id]

        @lists.push(inner)
        begin
          block.call
        ensure
          @lists.pop
        end
      end
      begin
        @doc.__send__(name, *args, **options, &wrapped)
      ensure
        @closed[inner.object_id] = true
      end
    else
      op << trailing if trailing
      list << op
      @doc.__send__(name, *args, **options)
    end
  end

  def respond_to_missing?(*)
    true
  end
end

# `font_families` as the example uses it: its updates are recorded.
class FamiliesRecorder
  def initialize(families, list)
    @families = families
    @list = list
  end

  def update(families)
    @list << ['font_families.update', OpValues.json(families)]
    @families.update(families)
  end
end

out = ARGV[0] or abort('usage: record_manual.rb OUT_DIR')
FileUtils.mkdir_p(out)
written = 0
skipped = []
Dir[File.join(PRAWN_DIR, 'manual', '*', '*.rb')].sort.each do |path|
  chapter = File.basename(File.dirname(path))
  name = File.basename(path, '.rb')
  Prawn::ManualBuilder::Chapter.last = nil
  begin
    load(path)
  rescue StandardError, ScriptError => e
    skipped << "#{chapter}/#{name}: does not load (#{e.class})"
    next
  end
  examples = Prawn::ManualBuilder::Chapter.last&.examples || []
  examples.each_with_index do |(options, block), i|
    id = examples.length > 1 ? "#{chapter}-#{name}-#{i + 1}" : "#{chapter}-#{name}"
    if options[:eval] == false
      skipped << "#{id}: not evaluated in the manual"
      next
    end
    doc = Prawn::Document.new
    recorder = Recorder.new(doc)
    begin
      Dir.chdir(PRAWN_DIR) { recorder.instance_eval(&block) }
      doc.render
    rescue Unrecordable => e
      skipped << "#{id}: #{e.message}"
      next
    rescue StandardError => e
      skipped << "#{id}: raised #{e.class}: #{e.message.lines.first&.chomp}"
      next
    end
    script = { 'ops' => recorder.recorded }
    File.write(File.join(out, "manual-#{id}.json"), "#{JSON.pretty_generate(script)}\n")
    written += 1
  end
end
puts "#{written} example(s) recorded, #{skipped.length} skipped"
skipped.each { |s| puts "  skipped #{s}" }
