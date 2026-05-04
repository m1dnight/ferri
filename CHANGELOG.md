# Changelog

Changelogs for Ferri.

## Unreleased



### Features



### Bug fixes



### Breaking changes



## 0.1.9



### Features

 - Added `--remote <host>:<port>` commandline argument to Ferri client.
 - Rate limit the throughput per session

### Bug fixes

- When a client disconnected from the server, the stream was not fully closed,
  only half (FIN). Now a RST frame is sent such that the stream is closed
  entirely and stops receiving.
 - Cleanup the readme file.


### Breaking changes



## 0.1.8



### Features



### Bug fixes



### Breaking changes



## 0.1.7

Friday, May 01, 2026

### Features

 - Add Windows CI build

### Bug fixes



### Breaking changes



## 0.1.6

Monday, April 27, 2026

### Features

 - Build changelog on homepage from Unclog changelog files.

### Bug fixes



### Breaking changes



## 0.1.5

Monday, April 27, 2026

 - Improved robustness for the handlers. There were same obvious DoS options, removed a few of those.
 - Added a dashboard to see live statistics on the server.
 - Added a homepage.

### Features



### Bug fixes



### Breaking changes


