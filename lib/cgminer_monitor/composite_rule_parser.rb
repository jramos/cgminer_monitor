# frozen_string_literal: true

module CgminerMonitor
  # Parses operator-defined composite alert rule expressions into
  # CompositeRule value objects. Grammar (deliberately tiny — see
  # docs/log_schema.md and README's "Composite alert rules" section
  # for the long form):
  #
  #   <expr>   := <clause> ( "&" <clause> )+    # at least 2 clauses
  #   <clause> := <metric> <op> <number>
  #   <metric> := one of ALLOWED_METRICS
  #   <op>     := one of ALLOWED_OPS  (longest-first matching: <= before <)
  #   <number> := decimal (sign + integer + optional fractional)
  #
  # Anything else — parens, OR (`|`), unknown metrics, unknown ops,
  # non-numeric thresholds, single-clause expressions — fails fast
  # at boot with a ConfigError that aggregates EVERY clause-level
  # problem in one message so the operator doesn't have to fix-and-
  # rerun N times.
  class CompositeRuleParser
    ALLOWED_METRICS = %w[ghs_5s temp_max offline_seconds].freeze
    # Order matters: longest-first so `<=` and `>=` aren't mis-tokenized
    # as `<` / `>`. The CLAUSE_REGEX below relies on alternation order.
    ALLOWED_OPS = %w[<= >= == < >].freeze
    RESERVED_NAMES = %w[hashrate_below temperature_above offline].freeze

    # Anchored, full-match regex per clause. The op alternation lists
    # multi-char ops first (Ruby Regexp alternation is left-to-right
    # and greedy on the matched alternative).
    CLAUSE_REGEX = /\A\s*(\w+)\s*(<=|>=|==|<|>)\s*(-?\d+(?:\.\d+)?)\s*\z/

    def self.parse(name, expr)
      new(name, expr).parse
    end

    def initialize(name, expr)
      @name = name.to_s
      @expr = expr.to_s
    end

    def parse
      raise_collision if RESERVED_NAMES.include?(@name)

      stripped = @expr.strip
      raise CgminerMonitor::ConfigError, "composite rule `#{@name}`: expression empty" if stripped.empty?

      # OR / `|` is explicitly out of scope for v1.4.0 — surface a
      # specific message rather than letting it fall through as
      # "unknown operator" or "unknown metric foo|bar".
      if stripped.include?('|')
        raise CgminerMonitor::ConfigError,
              "composite rule `#{@name}`: only AND (`&`) supported, found `|`"
      end

      raw_clauses = stripped.split('&')
      if raw_clauses.size < 2
        raise CgminerMonitor::ConfigError,
              "composite rule `#{@name}`: must have at least 2 clauses (single-clause " \
              'composites duplicate built-in rules — use the built-in instead)'
      end

      errors  = []
      clauses = raw_clauses.map { |raw| parse_clause(raw, errors) }

      raise CgminerMonitor::ConfigError, "composite rule `#{@name}`: #{errors.join('; ')}" if errors.any?

      CompositeRule.new(name: @name, clauses: clauses)
    end

    private

    def parse_clause(raw, errors)
      match = CLAUSE_REGEX.match(raw)
      unless match
        errors << "malformed clause `#{raw.strip}` (expected `metric op number`)"
        return nil
      end

      metric = match[1]
      op = match[2]
      threshold_str = match[3]

      unless ALLOWED_METRICS.include?(metric)
        errors << "unknown metric `#{metric}` (allowed: #{ALLOWED_METRICS.join(', ')})"
      end

      errors << "unknown operator `#{op}` in clause `#{raw.strip}`" unless ALLOWED_OPS.include?(op)

      threshold = Float(threshold_str, exception: false)
      errors << "non-numeric threshold `#{threshold_str}` in clause `#{raw.strip}`" if threshold.nil?

      { metric: metric, op: op, threshold: threshold }
    end

    def raise_collision
      raise CgminerMonitor::ConfigError,
            "composite rule `#{@name}`: name collides with a built-in rule " \
            "(reserved: #{RESERVED_NAMES.join(', ')})"
    end
  end
end
