# Logging

Learn how to enable and customize logging output from ReliaBLE.

## Overview

ReliaBLE provides robust logging to assist in development and debugging. To assist in your own application development 
these logs are exposed outside of the library. However, by default logging is 
turned off so you will need to make a few configuration adjustments if you wish to see the log messages.

ReliaBLE uses an open source logging library [Willow](https://github.com/Nike-Inc/Willow) for its logging 
functionality. Willow provides a high-performance, flexible logging system that allows you to configure the output of 
log messages. It also provides a number of built in log writers that can be used to write logs to different outputs.

## Logging Configuration

### Enable Logging
To enable logging output set the ``ReliaBLEConfig/loggingEnabled`` parameter to `true` when initializing ReliaBLE.

```swift
var config = ReliaBLEConfig()
config.loggingEnabled = true

var bleManager = ReliaBLEManager(config: config)
```

Logging can also be enabled/disabled at runtime. This allows leaving it disabled by default while providing a way
for users to enable it when facing an issue.

```swift
bleManager.loggingService.enabled = true
```

### Log Writers

By default, ReliaBLE will log messages to the console using `os_log`. This is sufficient for most development purposes. 
However, you may wish to use a more advanced logging system that can write logs to a file, observability service, or 
other output. To do this, you can configure the log writers in the ``ReliaBLEConfig`` object. The following example 
shows how to configure ReliaBLE to write logs to console using `print` instead of `os_log`.

```swift
var config = ReliaBLEConfig()
config.logWriters = [ConsoleWriter(method: .print)]
config.loggingEnabled = true

var bleManager = ReliaBLEManager(config: config)
```

For more details on how to create custom log writers, see [Willow's documentation](https://github.com/Nike-Inc/Willow?tab=readme-ov-file#log-writers).

### Log Level

By default, ReliaBLE will output log messages at `.debug` level and above. To adjust the level of output, set
``ReliaBLEConfig/logLevels`` to an array of desired ``LogLevel``. The following example shows how to configure log
output for `.warn` and `.error` log messages.

```swift
var config = ReliaBLEConfig()
config.logLevels = [LogLevel.warn, LogLevel.error]
config.loggingEnabled = true

var bleManager = ReliaBLEManager(config: config)
```
