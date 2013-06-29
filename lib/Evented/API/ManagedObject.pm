# Copyright (c) 2013 Mitchell Cooper
# ManagedObject represents an evented object managed by an API Engine. The API Engine
# is responsible for removing event callbacks that belong to a module when it is unloaded.
package Evented::API::ManagedObject;

use warnings;
use strict;
use 5.010;

our $VERSION = $Evented::API::Engine::VERSION;

1;
