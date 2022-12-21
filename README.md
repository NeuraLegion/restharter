# restharter

rest-har-ter is a simple tool to convert a scan's sitemap into a HAR file, and then use this HAR file to run a scan again without needing to re-crawl the site.

The tool uses the [BrightSec REST API](https://app.neuralegion.com/api/v1/docs/) to fetch the sitemap, and then uses the HAR library to transform the sitemap into a HAR file.

The HAR file will also be saved locally as reharter.har and will uploaded and used for restarting the scan.

## Installation

1. [Install Crystal](https://crystal-lang.org/docs/installation/)
2. `git clone` this repo
3. `cd` into the repo
4. `shards build`

## Usage

bin/restharter [scan_url] [api_key]
This will look like

```bash
bin/restharter https://app.neuralegion.com/scans/vEnJqXydfsdfsdfsdf 213213312
```

### Docker usage

1. clone the repo
2. `cd` into the repo
3. `docker build -t neuralegion/restharter .`

```bash
docker run -it neuralegion/restharter [scan_url] [api_key]
```

## Contributing

1. Fork it (<https://github.com/NeuraLegion/restharter/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Bar Hofesh](https://github.com/bararchy) - creator and maintainer
