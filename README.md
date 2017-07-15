# Evented::API::Engine

Evented::API::Engine is an [evented](#event-management)
API engine for Perl applications.

## Docs

* [Evented::API::Engine](doc/engine.pod)
* [Evented::API::Module](doc/module.pod)

## Features

### Module management

Modules are Perl packages which can be easily loaded, unloaded, and reloaded.
API Engine automatically tracks the changes made by each module and reverts them
upon unload, leaving no trace. With API Engine used properly, it is even
possible to reload your entire program without restarting it.

### Dependency resolution

API Engine automatically resolves dependencies of both modules and normal Perl
packages. It loads and unloads dependencies in the proper order.

### Event management

API Engine is *Evented* in that it tracks all
[Evented::Object](https://github.com/cooper/evented-object) callbacks attached
from within modules and automatically removes them upon unloading. This allows
you to employ events excessively without constantly worrying about their
eventual disposal.
