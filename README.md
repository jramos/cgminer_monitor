# CgminerMonitor

A monitor for cgminer instances. It periodically captures device, status and summary information to MongoDB.

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

#### Remote API Access

If connecting to a cgminer instance on any host other than 127.0.0.1, remote API access must be enabled. See [cgminer\_api\_client](https://github.com/jramos/cgminer_api_client#remote-api-access) for more information.

## Running

### Starting

    bin/cgminer_monitor start

### Stopping

    bin/cgminer_monitor stop

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