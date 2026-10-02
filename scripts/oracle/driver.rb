# frozen_string_literal: true

# Runs one operation script (docs/op-scripts.md) through Ruby Prawn.
#
#   ruby scripts/oracle/driver.rb SCRIPT.json OUT.pdf OUT.jsonl
#
# Writes the rendered PDF and the observation log: one JSON object per line,
# in the order the observations happened (query results, callback traces,
# errors). Prawn and its gems are loaded from .repos (see PLAN.md).

ROOT = File.expand_path('../..', __dir__)
REPOS = File.join(ROOT, '.repos')
GEMS = File.join(REPOS, 'gems')
$LOAD_PATH.unshift(File.join(REPOS, 'prawn', 'lib'))
%w[pdf-core-0.10.0 ttfunk-1.8.0].each { |g| $LOAD_PATH.unshift(File.join(GEMS, g, 'lib')) }

require 'json'
require 'prawn'

# The observation log.
class Log
  def initialize(path)
    @out = File.open(path, 'w')
  end

  def write(entry)
    @out.puts(JSON.generate(entry))
  end

  def close
    @out.close
  end
end

# A formatted-text callback that records where Prawn renders its fragment.
class TraceCallback
  def initialize(id, log, phase)
    @id = id
    @log = log
    @phase = phase
  end

  def render_behind(fragment)
    trace('render_behind', fragment) if @phase != 'in_front'
  end

  def render_in_front(fragment)
    trace('render_in_front', fragment) if @phase != 'behind'
  end

  private

  def trace(event, f)
    @log.write('trace' => @id, 'event' => event, 'text' => f.text, 'left' => f.left,
               'baseline' => f.baseline, 'width' => f.width, 'height' => f.height,
               'top' => f.top, 'bottom' => f.bottom)
  end
end

# Interprets the op language against a Prawn::Document.
class Driver
  def initialize(script, log)
    @script = script
    @log = log
  end

  def run(pdf_path)
    @doc = Prawn::Document.new(**value(@script.fetch('document', {})))
    ops(@script.fetch('ops'))
    @doc.render_file(pdf_path)
  end

  private

  def ops(list)
    list.each { |op| op(op) }
  end

  # [name, args...]: a "?" prefix logs the return value, "!raises" expects an
  # error, and a trailing {"block": [ops]} becomes the method's block.
  def op(op)
    name, *args = op
    case name
    when '!raises'
      expected, inner = args
      begin
        op(inner)
        @log.write('raises' => expected, 'error' => nil)
      rescue StandardError => e
        @log.write('raises' => expected, 'error' => e.class.name)
      end
    when /\A\?(.*)\z/
      @log.write('query' => op_label(Regexp.last_match(1), args),
                 'value' => observe(call(Regexp.last_match(1), args)))
    else
      call(name, args)
    end
  end

  def op_label(name, args)
    args.empty? ? name : [name, *args.reject { |a| a.is_a?(Hash) && a.key?('block') }]
  end

  # Calls a method path (`bounds.width`, `font_families.update`) on the
  # document.
  def call(path, args)
    *receivers, method = path.split('.')
    target = receivers.reduce(@doc) { |obj, m| obj.public_send(m) }
    block_arg = args.last.is_a?(Hash) && args.last.key?('block') ? args.last['block'] : nil
    args = args[0...-1] if block_arg
    positional = args.map { |a| value(a) }
    options = positional.last.is_a?(Hash) && symbol_keys?(positional.last) ? positional.pop : nil
    if block_arg
      blk = proc { ops(block_arg) }
      options ? target.public_send(method, *positional, **options, &blk) : target.public_send(method, *positional, &blk)
    else
      options ? target.public_send(method, *positional, **options) : target.public_send(method, *positional)
    end
  end

  def symbol_keys?(hash)
    !hash.empty? && hash.keys.all? { |k| k.is_a?(Symbol) }
  end

  # JSON → Ruby: hash keys become symbols (a "=" prefix keeps a string key),
  # strings starting with ":" become symbols, "$PRAWN/" and "$FIXTURES/"
  # resolve to files in the Prawn checkout, and {"trace": ID} becomes a
  # TraceCallback (in fragments) or a draw_text callback.
  def value(v)
    case v
    when Hash
      return TraceCallback.new(v['trace'], @log, v.fetch('phase', 'both')) if v.key?('trace') && v.size <= 2
      v.each_with_object({}) do |(k, x), h|
        key = k.start_with?('=') ? k[1..] : k.to_sym
        h[key] = key == :draw_text_callback ? draw_text_callback(x) : value(x)
      end
    when Array then v.map { |x| value(x) }
    when String then string(v)
    else v
    end
  end

  def string(s)
    if s.start_with?(':') && s.length > 1 then s[1..].to_sym
    elsif s.start_with?('$PRAWN/') then File.join(REPOS, 'prawn', s.delete_prefix('$PRAWN/'))
    else s
    end
  end

  def draw_text_callback(spec)
    id = spec.fetch('trace')
    log = @log
    lambda do |text, options|
      log.write('trace' => id, 'event' => 'draw_text', 'text' => text,
                'at' => options[:at], 'kerning' => options[:kerning])
    end
  end

  # Ruby → JSON-able observation.
  def observe(v)
    case v
    when Integer, Float, String, true, false, nil then v
    when Symbol then ":#{v}"
    when Array then v.map { |x| observe(x) }
    when Hash then v.to_h { |k, x| [k.to_s, observe(x)] }
    when Prawn::Document::BoundingBox
      { 'left' => v.left, 'bottom' => v.bottom, 'width' => v.width, 'height' => v.height,
        'absolute_left' => v.absolute_left, 'absolute_top' => v.absolute_top }
    when Prawn::Text::Formatted::Fragment then { 'text' => v.text, 'width' => v.width }
    else { 'class' => v.class.name }
    end
  end
end

# Prawn's warnings (Kernel#warn) are observations too.
module WarningLog
  class << self
    attr_accessor :log
  end

  def warn(message, *)
    WarningLog.log ? WarningLog.log.write('warning' => message.chomp) : super
  end
end
Warning.singleton_class.prepend(WarningLog)

if $PROGRAM_NAME == __FILE__
  script_path, pdf_path, log_path = ARGV
  abort('usage: driver.rb SCRIPT.json OUT.pdf OUT.jsonl') unless log_path
  log = Log.new(log_path)
  WarningLog.log = log
  begin
    Driver.new(JSON.parse(File.read(script_path, encoding: 'UTF-8')), log).run(pdf_path)
  ensure
    log.close
  end
end
