# Copyright (c) 2013-14, Mitchell Cooper
#
# @name:            "API::Methods"
# @version:         Evented::API::Engine->VERSION
# @package:         "Evented::API::Methods"
#
# @author.name:     "Mitchell Cooper"
# @author.website:  "https://github.com/cooper"
#
package Evented::API::Methods;

use warnings;
use strict;

use Evented::API::Hax qw(export_code delete_code);

our ($api, $mod);

sub init {
    my $fire = shift;
    
    # add methods.
    *API::Module::register_engine_method = *register_engine_method;
    *API::Module::register_module_method = *register_module_method;
    
    # register events.
    $mod->manage_object($api);
    $api->register_event('module.void' => \&any_void,
        name             => 'api.engine.methods.any.void',
        with_evented_obj => 1
    );
    
}

# our module void.
sub void {
    my $fire = shift;
    
    # delete these methods.
    undef *API::Module::register_engine_method;
    undef *API::Module::register_module_method;
    
    # delete all methods of all modules.
    any_void($_) foreach @{ $api->{loaded} };
    
}

# any module void.
sub any_void {
    my $module = shift;
    
    # fetch methods.
    my $e_methods = $module->retrieve('engine_methods', {});
    my $m_methods = $module->retrieve('module_methods', {});

    # delete methods.
    delete_method('Evented::API::Engine', $_) foreach keys %$e_methods;
    delete_method('Evented::API::Module', $_) foreach keys %$m_methods;
    
}

# add a method to symbol table.
sub add_method {
    my ($class, $method) = @_;
    return if $class->can($method);
    export_code($class, $method, sub {
        my ($obj, @args) = @_;
        
        # use Evented::Object's _fire_event() to use custom caller data.
        Evented::Object::_fire_event($obj, "method:$method", [caller 1], @args);
        
    });
}

# delete a method from symbol table.
sub delete_method {
    my ($class, $method) = @_;
    delete_code($class, $method);
}

# register a method to API Engine.
sub register_engine_method {
    my ($mod, $name, $code, %opts) = @_;
    
    # store method information.
    my $methods = $mod->retrieve('engine_methods', {})->{ $mod->full_name } //= {};
    $methods->{$name} = {
        %opts,
        code => $code
    };
    
    add_method('Evented::API::Engine', $name);
    return 1;
}

# register a method to API modules.
sub register_module_method {
    my ($mod, $name, $code, %opts) = @_;
    
    # store method information.
    my $methods = $mod->retrieve('module_methods', {})->{ $mod->full_name } //= {};
    $methods->{$name} = {
        %opts,
        code => $code
    };
    
    add_method('Evented::API::Module', $name);
    return 1;
}

$mod;
