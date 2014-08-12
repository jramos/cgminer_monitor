# CgminerMonitor

A monitor for cgminer instances. It periodically captures device, status and summary information to MongoDB. It also provides a Rails engine to allow querying cgminer log information from within a Rails application. See [cgminer_manager](https://github.com/jramos/cgminer_manager) for an example of this.

## Requirements

* [Ruby](https://www.ruby-lang.org) (~> 2.0.0, ~> 2.1.0)
* [bundler](http://bundler.io/) (~> 1.6.0)
* [mongodb](http://www.mongodb.org/) (~> 2.6)

## Dependencies

* [cgminer\_api\_client](https://github.com/jramos/cgminer_api_client) (~> 0.1.10)
* mongoid (= 4.0.0)
* rails (= 4.1.4)

## Installation

    git clone git@github.com:jramos/cgminer_monitor.git
    cd cgminer_monitor
    bundle install

## Configuration

### mongodb

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

## Running

### Starting

    bin/cgminer_monitor start

### Stopping

    bin/cgminer_monitor stop

## Rails Engine

### Installation

Add the following to your ``Gemfile``:

    gem 'cgminer_monitor', '~> 0.0.7'

Update your ``config/routes.rb`` file to mount the engine:

    mount CgminerMonitor::Engine => '/'

### API Endpoints

#### Graph Data

These endpoints return the previous hour's worth of hashrate data as a JSON array, with each data point being represented as ``[timestamp, avg_hashrate, hardware_error_hashrate]``.

##### Aggregate hashrate for the mining pool

* ``/cgminer_monitor/api/v1/graph_data/local_hashrate.json``

##### Hashrate for an individual miner

* ``/cgminer_monitor/api/v1/graph_data/miner_hashrate.json?miner_id=<miner-id>``

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