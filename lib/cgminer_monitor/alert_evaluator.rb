# frozen_string_literal: true

module CgminerMonitor
  # Runs once per poll tick (from Poller#poll_once, after poll.complete).
  # Reads the just-written Snapshot collection, evaluates threshold rules
  # per miner, transitions alert_states, and dispatches the webhook
  # through the injected client. Disabled path is a single early return
  # so production behavior is unchanged when alerts_enabled=false.
  class AlertEvaluator
    RULES = %w[hashrate_below temperature_above offline].freeze
    UNITS = { 'hashrate_below' => 'GH/s',
              'temperature_above' => 'C',
              'offline' => 'seconds' }.freeze
    # Maps each built-in rule name to the atom-keyed reading it consumes.
    # Composites read the same atoms directly via their #required_metrics.
    RULE_TO_ATOM = { 'hashrate_below' => 'ghs_5s',
                     'temperature_above' => 'temp_max',
                     'offline' => 'offline_seconds' }.freeze
    private_constant :RULE_TO_ATOM

    def initialize(config, webhook_client: nil, restart_schedule_client: nil)
      @config                  = config
      @webhook_client          = webhook_client || default_webhook_client(config)
      @restart_schedule_client = restart_schedule_client

      log_config_loaded if @config.alerts_enabled
    end

    def evaluate(now)
      return unless @config.alerts_enabled

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      counts     = { fired: 0, resolved: 0, rules_evaluated: 0 }
      readings_by_miner = miner_states(now)

      readings_by_miner.each do |miner, atom_readings|
        RULES.each do |rule|
          next if threshold_for(rule).nil? # built-in rule disabled

          observed = atom_readings[RULE_TO_ATOM[rule]]
          next if observed.nil? # data unavailable / suppressed

          counts[:rules_evaluated] += 1
          evaluate_built_in_rule(miner: miner, rule: rule, observed: observed,
                                 now: now, counts: counts)
        end
      end

      evaluate_composites(readings_by_miner, now, counts)

      Logger.info(event: 'alert.evaluation_complete',
                  duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1),
                  rules_evaluated: counts[:rules_evaluated],
                  fired_count: counts[:fired],
                  resolved_count: counts[:resolved])
    end

    private

    # Boot-time observability: one log line per AlertEvaluator instance
    # listing exactly which rules will run. Lets the operator confirm
    # at startup that their ENV parsed the way they intended.
    def log_config_loaded
      enabled_built_ins = RULES.reject { |r| threshold_for(r).nil? }
      Logger.info(event: 'alert.config_loaded',
                  built_in_rules: enabled_built_ins,
                  composite_rules: @config.composite_rules.map(&:name))
    end

    def evaluate_built_in_rule(miner:, rule:, observed:, now:, counts:)
      threshold = threshold_for(rule)
      violating = violates?(rule, observed, threshold)
      state_doc = AlertState.where(_id: AlertState.composite_id(miner, rule)).first
      common = { miner: miner, rule: rule, observed: observed, threshold: threshold,
                 unit: UNITS[rule], now: now, state_doc: state_doc }

      if violating
        handle_violating(**common, counts: counts)
      elsif state_doc&.state == 'violating'
        handle_resolved(**common, counts: counts)
      else
        ensure_ok_state(**common)
      end
    end

    # Composites iterate the SAME state-transition machinery as built-in
    # rules but pass string-typed threshold/observed and the structured
    # details: payload. Crucially: a composite that can't be evaluated
    # this tick (any required atom reading is nil) is SKIPPED — no state
    # write, no fire/resolve. This protects against transient bad
    # snapshots silently transitioning a real violating composite to ok.
    def evaluate_composites(readings_by_miner, now, counts)
      return if @config.composite_rules.empty?

      readings_by_miner.each do |miner, atom_readings|
        @config.composite_rules.each do |composite|
          next unless composite.evaluable?(atom_readings)

          counts[:rules_evaluated] += 1
          evaluate_composite_rule(composite: composite, miner: miner,
                                  readings: atom_readings, now: now, counts: counts)
        end
      end
    end

    def evaluate_composite_rule(composite:, miner:, readings:, now:, counts:)
      violating = composite.violates?(readings)
      state_doc = AlertState.where(_id: AlertState.composite_id(miner, composite.name)).first
      common = {
        miner: miner, rule: composite.name,
        observed: composite.payload_observed(readings),
        threshold: composite.payload_threshold,
        unit: nil, now: now, state_doc: state_doc,
        # Composites carry per-clause structure on the wire AND in state.
        details: composite.payload_details(readings),
        last_observed_components: composite.payload_details(readings)['clauses']
      }

      if violating
        handle_violating(**common, counts: counts)
      elsif state_doc&.state == 'violating'
        handle_resolved(**common, counts: counts)
      else
        ensure_ok_state(**common)
      end
    end

    def handle_violating(miner:, rule:, observed:, threshold:, unit:, state_doc:, now:, counts:,
                         details: nil, last_observed_components: nil)
      was_violating = state_doc&.state == 'violating'
      cooldown_elapsed = was_violating && state_doc.last_fired_at &&
                         (now - state_doc.last_fired_at) >= @config.alerts_cooldown_seconds
      fire = !was_violating || cooldown_elapsed

      upsert_state(miner: miner, rule: rule, observed: observed, threshold: threshold,
                   state: 'violating',
                   last_observed_components: last_observed_components,
                   last_fired_at: fire ? now : state_doc&.last_fired_at,
                   last_transition_at: was_violating ? state_doc.last_transition_at : now)

      return unless fire

      counts[:fired] += 1
      emit(event: 'alert.fired', level: :warn,
           miner: miner, rule: rule, observed: observed, threshold: threshold,
           unit: unit, now: now, details: details)
    end

    def handle_resolved(miner:, rule:, observed:, threshold:, unit:, state_doc:, now:, counts:,
                        details: nil, last_observed_components: nil)
      upsert_state(miner: miner, rule: rule, observed: observed, threshold: threshold,
                   state: 'ok',
                   last_observed_components: last_observed_components,
                   last_fired_at: state_doc&.last_fired_at,
                   last_transition_at: now)
      counts[:resolved] += 1
      emit(event: 'alert.resolved', level: :info,
           miner: miner, rule: rule, observed: observed, threshold: threshold,
           unit: unit, now: now, details: details)
    end

    def ensure_ok_state(miner:, rule:, observed:, threshold:, unit:, state_doc:, now:,
                        details: nil, last_observed_components: nil)
      _ = unit # not used in the ok path; accepted for keyword-symmetry with handle_*
      _ = details
      return if state_doc&.state == 'ok' # no-op; avoid a Mongo write per tick

      upsert_state(miner: miner, rule: rule, observed: observed, threshold: threshold,
                   state: 'ok',
                   last_observed_components: last_observed_components,
                   last_fired_at: nil,
                   last_transition_at: now)
    end

    # `last_observed` is Float on AlertState; for composites we pass a
    # String through `observed:` so the wire payload is human-readable,
    # but we MUST NOT let that String reach the Float field (Mongoid
    # would silently coerce it to 0.0). Built-in callers continue to
    # pass a Float; composites store the per-clause hash in
    # `last_observed_components` and nil-out `last_observed`.
    def upsert_state(miner:, rule:, observed:, threshold:, state:,
                     last_fired_at:, last_transition_at:, last_observed_components: nil)
      doc = AlertState.find_or_initialize_by(_id: AlertState.composite_id(miner, rule))
      doc.assign_attributes(miner: miner, rule: rule, state: state,
                            threshold: numeric_or_nil(threshold),
                            last_observed: numeric_or_nil(observed),
                            last_observed_components: last_observed_components,
                            last_fired_at: last_fired_at,
                            last_transition_at: last_transition_at)
      doc.save!
    rescue Mongo::Error => e
      Logger.error(event: 'alert.state_write_failed', miner: miner, rule: rule,
                   error: e.class.to_s, message: e.message)
    end

    def numeric_or_nil(value)
      value.is_a?(Numeric) ? value : nil
    end

    def emit(event:, level:, miner:, rule:, observed:, threshold:, unit:, now:, details: nil)
      log_payload = { event: event, miner: miner, rule: rule,
                      threshold: threshold, observed: observed, unit: unit }
      log_payload[:details] = details unless details.nil?
      Logger.public_send(level, **log_payload)

      return unless @webhook_client

      @webhook_client.fire(event: event, miner: miner, rule: rule,
                           threshold: threshold, observed: observed,
                           unit: unit, fired_at: now, details: details)
    end

    def threshold_for(rule)
      case rule
      when 'hashrate_below'    then @config.alerts_hashrate_min_ghs
      when 'temperature_above' then @config.alerts_temperature_max_c
      when 'offline'           then @config.alerts_offline_after_seconds
      end
    end

    def violates?(rule, observed, threshold)
      case rule
      when 'hashrate_below'    then observed < threshold
      when 'temperature_above' then observed > threshold
      when 'offline'           then observed >= threshold
      end
    end

    # Returns { miner_id => { 'ghs_5s' => val, 'temp_max' => val, 'offline_seconds' => val } }.
    # Each atom is read whenever ANY rule (built-in OR composite) needs it,
    # so disabling the built-in temperature_above rule but defining a
    # composite that uses temp_max still pulls the devs snapshot. Atom is
    # nil when no rule needs it OR when the underlying data is missing.
    def miner_states(now)
      atom_readings = Hash.new { |h, k| h[k] = blank_atom_readings }

      if atom_required?('ghs_5s')
        Snapshot.where(command: 'summary', ok: true).each do |snap|
          atom_readings[snap.miner]['ghs_5s'] = extract_hashrate(snap)
        end
      end

      if atom_required?('temp_max')
        Snapshot.where(command: 'devs', ok: true).each do |snap|
          atom_readings[snap.miner]['temp_max'] = extract_temperature(snap)
        end
      end

      populate_offline_readings(atom_readings, now) if atom_required?('offline_seconds')

      atom_readings
    end

    def blank_atom_readings
      { 'ghs_5s' => nil, 'temp_max' => nil, 'offline_seconds' => nil }
    end

    # True when at least one rule (built-in or composite) consumes
    # the atom — drives whether `miner_states` bothers reading the
    # underlying snapshot/sample at all.
    def atom_required?(atom)
      built_in_rule = RULE_TO_ATOM.invert[atom]
      return true if built_in_rule && !threshold_for(built_in_rule).nil?

      @config.composite_rules.any? { |c| c.required_metrics.include?(atom) }
    end

    # Offline = seconds since the miner's last successful poll.
    # Sourced from the `Sample` time-series collection, not `Snapshot`:
    # Snapshot keeps only one doc per (miner, command) and overwrites
    # the `ok` field on failure, so it can't tell us when the miner
    # last succeeded. The synthetic `poll/ok` samples the Poller writes
    # every tick ARE the history. Falls back to the miner's earliest
    # poll sample when it has never succeeded — gives a finite,
    # serializable "seconds since we first saw this miner" rather than
    # Infinity (which would break the webhook body's JSON.generate).
    def populate_offline_readings(atom_readings, now)
      last_ok  = SampleQuery.last_ok_at_per_miner
      first_at = SampleQuery.first_poll_at_per_miner
      SnapshotQuery.miners.each do |entry|
        miner = entry[:miner]

        # Read-side gate: when the manager has the miner in its
        # restart-window, suppress this miner's offline_seconds atom
        # for this tick so the nightly restart doesn't page on its
        # way down. Both the built-in `offline` rule AND any composite
        # that uses `offline_seconds` see nil and skip — composites
        # via #evaluable?, built-ins via the `next if observed.nil?`
        # gate in evaluate(). Schedule lookup is fail-open (returns
        # false on fetch failure), so a manager outage doesn't
        # blanket-suppress real outages.
        if @restart_schedule_client&.in_restart_window?(miner, now)
          atom_readings[miner]['offline_seconds'] = nil
          Logger.info(event: 'alert.suppressed_during_restart_window',
                      miner: miner, rule: 'offline')
          next
        end

        reference = last_ok[miner] || first_at[miner]
        atom_readings[miner]['offline_seconds'] = reference ? (now - reference).to_f : 0.0
      end
    end

    def default_webhook_client(config)
      return nil unless config.alerts_enabled

      WebhookClient.new(config)
    end

    # Defensive on every structural assumption: cgminer firmware drift,
    # proxies, and legacy Snapshot docs have all been observed to
    # return odd shapes (Hash where Array was expected, string primitives
    # in an array of hashes, missing keys). A TypeError here would
    # unwind into Poller's rescue and silently drop alert evaluation
    # for EVERY OTHER miner on the tick — one bad rig poisoning the
    # whole fleet's alerts. Return nil for any malformed input so the
    # rule is skipped for just this miner and the tick continues.
    def extract_hashrate(snapshot)
      summary = snapshot.response&.dig('SUMMARY')
      entry = summary.is_a?(Array) ? summary.first : nil
      return nil unless entry.is_a?(Hash)

      raw = entry['GHS 5s'] || entry['ghs_5s']
      raw.nil? ? nil : Float(raw, exception: false)
    end

    def extract_temperature(snapshot)
      devices = snapshot.response&.dig('DEVS')
      return nil unless devices.is_a?(Array)

      temps = devices.grep(Hash)
                     .map { |d| Float(d['Temperature'] || d['temperature'], exception: false) }
                     .compact
      temps.empty? ? nil : temps.max
    end
  end
end
