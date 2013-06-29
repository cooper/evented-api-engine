# Copyright (c) 2013 Mitchell Cooper
# the API Engine is in charge of loading and unloading modules.
# It also handles dependencies and feature availability.
package Evented::API::Engine;

use warnings;
use strict;
use 5.010;

use Evented::Object;
use parent 'Evented::Object';

use Evented::API::Module;
use Evented::API::Hax;

our $VERSION = '0.1';

# create a new API Engine.
sub new {
    my ($class, %opts) = @_;
    return bless \%opts, $class;
}

#########################
### MODULE MANAGEMENT ###
#########################

# load modules initially, i.e. from a configuration file.
sub load_modules_initially {
}

# load a module.
sub load_module {
}

# unload a module.
sub unload_module {
}

####################
### DATA STORAGE ###
####################

# store a piece of data specific to this API Engine.
sub store {
}

# fetch a piece of data specific to this API Engine.
sub retrieve {
}

#######################
### DYNAMIC METHODS ###
#######################

# add new methods to the API Engine.
sub add_methods {
}

# add new methods to all modules in the API Engine.
sub add_module_methods {
}

################
### FEATURES ###
################

sub add_feature {
}

sub remove_feature {
}

sub has_feature {
}

1;
