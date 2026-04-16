# Migrating from cgminer_monitor 0.x to 1.0

cgminer_monitor 1.0 is a ground-up rewrite. It is no longer a Rails engine — it is a standalone HTTP service. Run it as a sibling process (docker-compose example included), and replace direct Mongoid model access with HTTP calls.

## Breaking changes

- The gem no longer provides a Rails engine, Mongoid documents, or rake tasks.
- The `CgminerMonitor::Daemon` (start/stop/restart/status) is replaced by `cgminer_monitor run` as a foreground process. Use your process supervisor (systemd, Docker, etc.) for lifecycle management.
- All MongoDB access is internal. Consumers interact via the HTTP API only.
- Ruby 3.2+ is required (was Ruby 2.0).
- MongoDB 5.0+ is required (was MongoDB 2.6).

## Migration table for cgminer_manager consumers

| cgminer_manager today | cgminer_manager after |
|---|---|
| `gem 'cgminer_monitor', '~> 0.2.23'` | Drop the gem dependency entirely |
| `mount CgminerMonitor::Engine => '/'` in `routes.rb` | Delete the mount; cgminer_monitor is a separate process |
| `CgminerMonitor::Document::Summary.last_entry` (and `Devs`, `Pools`, `Stats`) | HTTP call to `GET /v2/miners/:id/summary` (or `/devices`, `/pools`, `/stats`) |
| Index-positional `last_entry[:results][index]` | Key by `host:port` from the API response |
| HAML partials hitting `/cgminer_monitor/api/v1/graph_data/...` | Hit `/v2/graph_data/<metric>` on the cgminer_monitor host:port |
| `application.js` hitting `/cgminer_monitor/api/v1/ping.json` | Hit `/v2/healthz`; expect `status: "healthy"` instead of `status: "running"` |
| Mongoid 4 + parallel `mongoid.yml` | Mongoid no longer required by cgminer_manager at all |

## Step-by-step

1. **Deploy cgminer_monitor 1.0 as a standalone service.**
   Use `docker-compose up` or install the gem and run `cgminer_monitor run` under systemd. See the [README](README.md) for details.

2. **Remove the gem dependency from cgminer_manager.**
   Delete `gem 'cgminer_monitor'` from your Gemfile. Delete `mount CgminerMonitor::Engine => '/'` from `routes.rb`.

3. **Replace direct Mongoid model access with HTTP calls.**
   Where cgminer_manager previously called `CgminerMonitor::Document::Summary.last_entry`, make an HTTP request to cgminer_monitor's API instead:

   ```ruby
   # Before (0.x):
   summary = CgminerMonitor::Document::Summary.last_entry
   ghs_5s = summary.results[0]["GHS 5s"]

   # After (1.0):
   require 'net/http'
   require 'json'

   uri = URI("http://localhost:9292/v2/miners/192.168.1.10%3A4028/summary")
   response = JSON.parse(Net::HTTP.get(uri))
   ghs_5s = response["response"]["SUMMARY"].first["GHS 5s"]
   ```

4. **Update graph data endpoints.**
   Replace `/cgminer_monitor/api/v1/graph_data/local_hashrate.json` with `/v2/graph_data/hashrate`. The response format has changed — see the [API reference](README.md#api-reference).

5. **Update health checks.**
   Replace `/cgminer_monitor/api/v1/ping.json` with `/v2/healthz`. The new response includes `status` (healthy/starting/degraded), `mongo` (boolean), and miner availability counts.

6. **Remove Mongoid from cgminer_manager** (if it was only used for cgminer_monitor documents).
   Delete `config/mongoid.yml` and the `mongoid` gem dependency.

## Data migration

No data migration is needed. The old Mongoid 4 document collections (`cgminer_monitor_summaries`, `cgminer_monitor_devs`, etc.) were silently failing writes against Mongoid 7+ due to missing `field` declarations. There is no production data to migrate. The new `samples` and `latest_snapshot` collections start fresh.
