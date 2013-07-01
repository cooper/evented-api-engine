# Copyright (c) 2013 Mitchell Cooper
# Module represents an API module and provides an interface for managing one.
package Evented::API::Module;

use warnings;
use strict;
use 5.010;

use Evented::Object;
use parent 'Evented::Object';

our $VERSION = $Evented::API::Engine::VERSION;

sub new {
    my ($class, %opts) = @_;
    return bless \%opts, $class;
}

1;
