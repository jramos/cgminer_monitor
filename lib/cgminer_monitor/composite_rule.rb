# frozen_string_literal: true

module CgminerMonitor
  # Value object: an operator-defined alert rule that combines
  # multiple atomic-metric clauses under AND semantics. Constructed
  # by CompositeRuleParser at boot; never instantiated directly by
  # the evaluator. The evaluator iterates `@config.composite_rules`
  # and calls #evaluable? / #violates? / #payload_* per (rule, miner)
  # pair using the same lifecycle (handle_violating / handle_resolved /
  # ensure_ok_state) as the built-in rules.
  #
  # Frozen after construction so the boot-time parsed form can't
  # drift while the poll loop is running.
  class CompositeRule
    attr_reader :name, :clauses, :required_metrics

    def initialize(name:, clauses:)
      @name             = name
      @clauses          = clauses.freeze
      @required_metrics = clauses.map { |c| c[:metric] }.uniq.freeze
      @sorted_clauses   = clauses.sort_by { |c| c[:metric] }.freeze
      freeze
    end

    # True when every metric this rule references has a non-nil
    # reading on this tick. False → caller must skip this rule for
    # this miner this tick (NO state write, NO emit). Mirrors the
    # `next if observed.nil?` semantics the built-in rules use, but
    # at the rule level instead of the per-rule loop.
    def evaluable?(readings)
      required_metrics.all? { |m| !readings[m].nil? }
    end

    # AND across clauses. Caller must check #evaluable? first; we
    # raise rather than silently treating "missing" as "not
    # violating" (which would let a transient bad snapshot transition
    # a real violating composite to ok).
    def violates?(readings)
      missing = required_metrics.reject { |m| readings.key?(m) && !readings[m].nil? }
      raise ArgumentError, "missing reading(s) for: #{missing.join(', ')}" if missing.any?

      @clauses.all? { |c| clause_violates?(readings[c[:metric]], c[:op], c[:threshold]) }
    end

    # Canonical, deterministic form. Sorted by metric name so a parse
    # → render → parse round-trip is stable. Used in the webhook's
    # top-level `threshold:` field for composites (Slack/Discord
    # render this string verbatim).
    def payload_threshold
      sorted_clauses
        .map { |c| "#{c[:metric]}#{c[:op]}#{c[:threshold]}" }
        .join(' & ')
    end

    # Space-separated metric=value pairs, sorted by metric. Used in
    # the webhook's top-level `observed:` field for composites.
    def payload_observed(readings)
      sorted_clauses
        .map { |c| "#{c[:metric]}=#{readings[c[:metric]]}" }
        .join(' ')
    end

    # Structured form for the new `details:` webhook field (generic
    # format only; Slack/Discord render the strings above). Includes
    # the canonical expression so consumers don't have to re-derive
    # the rule definition. ALL string keys + Float/String values for
    # Mongoid + JSON cleanliness.
    def payload_details(readings)
      {
        'expression' => payload_threshold,
        'clauses' => sorted_clauses.to_h do |c|
          [c[:metric], {
            'observed' => readings[c[:metric]],
            'threshold' => c[:threshold],
            'op' => c[:op]
          }]
        end
      }
    end

    private

    attr_reader :sorted_clauses

    def clause_violates?(observed, operator, threshold)
      case operator
      when '<'  then observed < threshold
      when '>'  then observed > threshold
      when '<=' then observed <= threshold
      when '>=' then observed >= threshold
      when '==' then observed == threshold
      end
    end
  end
end
