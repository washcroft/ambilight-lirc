# ambilight-lirc
A Perl script to integrate [Hyperion](https://github.com/hyperion-project/hyperion), [HomeBridge](https://github.com/nfarina/homebridge) and [lirc](http://www.lirc.org/).

# About
This Perl script will intercept IR commands via lirc (i.e. TV power on and TV power off) and will turn on/off Hyperion ambilight accordingly.

It does this via the [homebridge-hyperion](https://github.com/Danimal4326/homebridge-hyperion) plugin within [HomeBridge](https://github.com/nfarina/homebridge) to ensure the switch states in HomeKit are accurate.