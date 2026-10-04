# frozen_string_literal: true

# Runs one operation script (docs/op-scripts.md) through Ruby Prawn.
#
#   ruby scripts/oracle/driver.rb SCRIPT.json OUT.pdf OUT.jsonl
#   ruby scripts/oracle/driver.rb --batch LIST   (see the end of this file)
#
# Writes the rendered PDF and the observation log: one JSON object per line,
# in the order the observations happened (query results, callback traces,
# errors). Prawn and its gems are loaded from .repos (see PLAN.md).

ROOT = File.expand_path('../..', __dir__)
REPOS = File.join(ROOT, '.repos')
GEMS = File.join(REPOS, 'gems')
PRAWN_DIR = "#{File.join(REPOS, 'prawn')}/"
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
  # draw: ops run after each logged call (drawing from inside the callback)
  def initialize(id, log, phase, draw = nil, driver = nil)
    @id = id
    @log = log
    @phase = phase
    @draw = draw
    @driver = driver
  end

  def render_behind(fragment)
    return if @phase == 'in_front'

    trace('render_behind', fragment)
    @driver.send(:ops, @draw) if @draw
  end

  def render_in_front(fragment)
    return if @phase == 'behind'

    trace('render_in_front', fragment)
    @driver.send(:ops, @draw) if @draw
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
    @receivers = [@doc]
    ops(@script.fetch('ops'))
    @doc.render_file(pdf_path)
  end

  private

  def ops(list)
    list.each { |op| op(op) }
  end

  # receiver: self inside the block; home: the receiver when the block was
  # made (deferred blocks such as on_page_create run later, elsewhere).
  def block_ops(receiver, home, list)
    @receivers.push(receiver.equal?(self) ? home : receiver)
    ops(list)
  ensure
    @receivers.pop
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
  # current receiver: the document, or inside a block Prawn instance_evals
  # (`outline.define`), the block's self.
  def call(path, args)
    *receivers, method = path.split('.')
    target = receivers.reduce(@receivers.last) { |obj, m| obj.public_send(m) }
    block_arg = nil
    if args.last.is_a?(Hash) && args.last.key?('block')
      rest = args.last.reject { |k, _| k == 'block' }
      block_arg = args.last['block']
      args = args[0...-1] + (rest.empty? ? [] : [rest])
    end
    positional = args.map { |a| value(a) }
    options = positional.last.is_a?(Hash) && symbol_keys?(positional.last) ? positional.pop : nil
    if block_arg
      # Under instance_eval, self in the block is Prawn's object, not the
      # driver: ops then target it.
      driver = self
      home = @receivers.last
      blk = proc { driver.send(:block_ops, self, home, block_arg) }
      options ? target.public_send(method, *positional, **options, &blk) : target.public_send(method, *positional, &blk)
    else
      options ? target.public_send(method, *positional, **options) : target.public_send(method, *positional)
    end
  end

  def symbol_keys?(hash)
    !hash.empty? && hash.keys.all? { |k| k.is_a?(Symbol) }
  end

  # JSON → Ruby: hash keys become symbols (a "=" prefix keeps a string key),
  # strings starting with ":" become symbols ("::" escapes a literal colon),
  # "$PRAWN/" resolves to a file in the Prawn checkout, and {"trace": ID}
  # becomes a TraceCallback (in fragments) or a draw_text callback.
  def value(v)
    case v
    when Hash
      if v.key?('trace') && (v.keys - %w[trace phase draw]).empty?
        return TraceCallback.new(v['trace'], @log, v.fetch('phase', 'both'), v['draw'], self)
      end
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
    if s.start_with?('::') then s[1..]
    elsif s.start_with?(':') && s.length > 1 then s[1..].to_sym
    elsif s.start_with?('$PRAWN/') then File.join(REPOS, 'prawn', s.delete_prefix('$PRAWN/'))
    else s
    end
  end

  def draw_text_callback(spec)
    id = spec.fetch('trace')
    draw = spec['draw']
    log = @log
    driver = self
    lambda do |text, options|
      log.write('trace' => id, 'event' => 'draw_text', 'text' => text,
                'at' => options[:at], 'kerning' => options[:kerning])
      driver.send(:ops, draw) if draw
    end
  end

  # Ruby → JSON-able observation.
  def observe(v)
    case v
    when String then v.gsub(PRAWN_DIR, '$PRAWN/')
    when Integer, Float, true, false, nil then v
    when Symbol then ":#{v}"
    when Array then v.map { |x| observe(x) }
    when Hash then v.to_h { |k, x| [observe(k.to_s), observe(x)] }
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

# Runs the script at script_path, writing pdf_path and log_path, from what a
# fresh process starts with: Prawn's process-wide state (the warning about
# built-in fonts given once, the count naming repeaters' stamps) is reset.
def run_script(script_path, pdf_path, log_path)
  Prawn::Fonts::AFM.hide_m17n_warning = false
  Prawn::Repeater.count = 0
  log = Log.new(log_path)
  WarningLog.log = log
  begin
    Driver.new(JSON.parse(File.read(script_path, encoding: 'UTF-8')), log).run(pdf_path)
  ensure
    WarningLog.log = nil
    log.close
  end
end

if $PROGRAM_NAME == __FILE__
  # Fixed warning settings, whatever RUBYOPT says: Kernel#warn reaches the
  # log unless $VERBOSE is nil (-W0); Ruby's own deprecation and
  # experimental warnings stay off.
  $VERBOSE = false
  Warning[:deprecated] = false
  Warning[:experimental] = false
  if ARGV[0] == '--batch'
    # Many scripts in one process (Prawn loads once): each line of LIST is
    # SCRIPT.json, OUT.pdf and OUT.jsonl separated by tabs; one line per
    # script goes to stdout, `ok` or `error` and what was raised.
    abort('usage: driver.rb --batch LIST') unless ARGV[1]
    File.readlines(ARGV[1], chomp: true).each do |line|
      next if line.empty?

      script_path, pdf_path, log_path = line.split("\t")
      begin
        run_script(script_path, pdf_path, log_path)
        puts "ok\t#{script_path}"
      rescue SystemCallError, IOError
        # writing or reading files failed: the harness, not the script
        raise
      rescue StandardError => e
        puts "error\t#{script_path}\t#{e.class}: #{e.message.lines.first&.chomp}"
      end
      $stdout.flush
    end
  else
    script_path, pdf_path, log_path = ARGV
    abort('usage: driver.rb SCRIPT.json OUT.pdf OUT.jsonl') unless log_path
    run_script(script_path, pdf_path, log_path)
  end
end
