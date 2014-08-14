# CgminerMonitor

A monitor for cgminer instances. It periodically captures device, status and summary information to MongoDB. It also provides a Rails engine to allow querying cgminer log information from within a Rails application. See [cgminer_manager](https://github.com/jramos/cgminer_manager) for an example of this type of integration.

## Requirements

* [Ruby](https://www.ruby-lang.org) (~> 2.0.0, ~> 2.1.0)
* [bundler](http://bundler.io/) (~> 1.6.0)
* [mongodb](http://www.mongodb.org/) (~> 2.6)

## Dependencies

* [cgminer\_api\_client](https://github.com/jramos/cgminer_api_client) (~> 0.1.14)
* mongoid (= 4.0.0)
* rails (= 4.1.4)
* rake (~> 10.0)

## Installation

### Bundler

Add the following to your ``Gemfile``:

    gem 'cgminer_monitor', '~> 0.1.9'

### RubyGems

    $ gem install cgminer_monitor

### Manually

    $ git clone git@github.com:jramos/cgminer_monitor.git

## Configuration

### mongoid

Copy [``config/mongoid.yml.example``](https://github.com/jramos/cgminer_monitor/blob/master/config/mongoid.yml.example) to ``config/mongoid.yml`` and update as necessary.

    production:
      sessions:
        default:
          database: cgminer_monitor
          hosts:
            - localhost:27017

### cgminer\_api\_client

Copy [``config/miners.yml.example``](https://github.com/jramos/cgminer_monitor/blob/master/config/miners.yml.example) to ``config/miners.yml`` and update with the IP addresses (and optional ports) of your cgminer instances. E.g.

    # connect to localhost on the default port (4028)
    - host: 127.0.0.1
    # connect to 192.168.1.1 on a non-standard port (1234)
    - host: 192.168.1.1
      port: 1234

See [cgminer\_api\_client](https://github.com/jramos/cgminer_api_client#configuration) for more information.

## Indexing

After configuring mongoid, be sure to create the indexes for the log documents.

    $ rake cgminer_monitor:create_indexes

## Monitoring Daemon

### Starting

    $ cgminer_monitor start

### Stopping

    $ cgminer_monitor stop

### Restarting

    $ cgminer_monitor restart

### Checking Status

    $ cgminer_monitor status

### Reporting version

    $ cgminer_monitor version

## Rails Engine

### Installation

Update your ``config/routes.rb`` file to mount the engine API endpoints:

    mount CgminerMonitor::Engine => '/'

### API Endpoints

#### Ping

Checks the status of the cgminer_monitor process. Response ``status`` element will either be "``running``" or "``stopped``".

* ``/cgminer_monitor/api/v1/ping.json``

Example response:

    {
        "timestamp": 1407879277,
        "status": "running"
    }

#### Graph Data

Each endpoint returns the previous hour's worth of data as a JSON array of data points.

##### Hashrates

Endpoints:

* ``/cgminer_monitor/api/v1/graph_data/local_hashrate.json``
* ``/cgminer_monitor/api/v1/graph_data/miner_hashrate.json?miner_id=<miner-id>``

Data point response format:

    [
        timestamp,
        avg_hashrate,
        pool_rejected_hashrate,
        pool_stale_hashrate,
        hardware_error_hashrate
    ]

##### Temperatures

Endpoints:

* ``/cgminer_monitor/api/v1/graph_data/local_temperature.json``
* ``/cgminer_monitor/api/v1/graph_data/miner_temperature.json?miner_id=<miner-id>``

Data point response format:

    [
        timestamp,
        min_temp,
        avg_temp,
        max_temp
    ]

##### Availability

Endpoints:

* ``/cgminer_monitor/api/v1/graph_data/local_availability.json``
* ``/cgminer_monitor/api/v1/graph_data/miner_availability.json?miner_id=<miner-id>``

Data point response format:

    [
        timestamp,
        num_available,
        num_configured
    ]

## Contributing

1. Fork it ( https://github.com/jramos/cgminer_monitor/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Donating

If you find this application useful, please consider donating.

BTC: ``***REMOVED***``

## License

Code released under [the MIT license](LICENSE.txt).