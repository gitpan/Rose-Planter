package Rose::Planter;

use warnings;
use strict;

=head1 NAME

Rose::Planter - Keep track of classes created with Rose::DB::Object::Loader.

=cut

our $VERSION = '0.29';

=head1 SYNOPSIS

    use Rose::Planter
        loader_params => {
            class_prefix => "My::Object",
            db_class     => "My::DB",
        },
        nested_tables => {
            foo => [ qw(params) ]
        },
        convention_manager_params => {};

    my $class = Rose::Planter->find_class("my_table");

    my $object = Rose::Planter->find_object("my_table","my_key1","my_key2");

=head1 DESCRIPTION

This is a thin layer above Rose::DB::Object::Loader for keeping
track of and managing classes which are created based on a database
schema.

This module works well with L<Module::Build::Database> and
L<Clustericious> to create a simple RESTful service based on
a database schema.  It can be used to provide a common base
class, conventions, and settings for a collection of services,
as well as describe which tables within a schema should be
coupled with other tables during CRUD operations.

By default the loader is told that the base_class should be
L<Rose::Planter::Soil>.  You can send "base_classes" or
just "base_class" as loader_params to changes this.

nested_tables will cause find_object to automatically join tables
connected to the primary table with a many-to-one relationship.

=head1 FUNCTIONS

=over

=cut

use Rose::DB::Object::Loader;
use Rose::Planter::ConventionManager;
use Rose::Planter::Gardener;
use List::MoreUtils qw/mesh/;
use strict;
use warnings;

our %table2Class;    # mapping from table name to class name.
our %deftable2Class; # map for prefix of tables ending in _def to class name.
our %plural2Class;   # map plurals of tables to manager classes
{
my $_logfp;
sub _trace {
    # Hook for tracing at compile time
    return unless $ENV{ROSE_PLANTER_DEBUG};
    my $msg = shift;
    unless ($_logfp) {
        $_logfp = IO::File->new(">>/tmp/rose.log");
    }
    print $_logfp "$msg\n";
}
}

sub import {
    my ($class, %params) = @_;
    $class->_setup_classes(%params);
}

sub _setup_classes {
    my $class = shift;
    my %params = @_;

    my %loader_params = %{ $params{loader_params} || {} };

    unless ($loader_params{base_class} || $loader_params{base_classes}) {
        $loader_params{base_class} = "Rose::Planter::Soil";
    }

    unless ($loader_params{manager_base_class} || $loader_params{manager_base_classes}) {
        $loader_params{manager_base_class} = "Rose::Planter::Gardener";
    }

    my $loader = Rose::DB::Object::Loader->new(
        warn_on_missing_primary_key => 1,
        convention_manager          => "Rose::Planter::ConventionManager",
        %loader_params
    );
    my @made = $loader->make_classes; # include_tables => ...
    die "did not make any classes" unless @made > 0;
    # Keep track of what we made
    for my $made (@made) {
        if ( $made->can("meta") ) {
            _trace "Made object class $made";
            my $table = $made->meta->table;
            warn "replacing $table ($table2Class{$table}) with $made"
              if $table2Class{$table} && $table2Class{$table} ne $made;
            $table2Class{$table} = $made;
            if ( $table =~ /^(.*)_def$/ ) {
                warn "replacing $1 ($table2Class{$1}) with $made"
                  if $table2Class{$1} && $table2Class{$1} ne $made;
                $deftable2Class{$1} = $made;
            }
        }
        if ( $made->can("get_objects") ) {
            _trace "Made manager class $made";
            my $object_class = $made->object_class;
            my $table        = $object_class->meta->table;
            $table =~ s/_def//;
            my $plural = Rose::Planter::ConventionManager->new()->singular_to_plural($table);
            $plural2Class{$plural} = $made;
        }
        # Load any extra functions, too.
        eval "use $made";
        die "Errors using $made : $@" if $@ && $@ !~ /Can't locate/;
    }

    my %nested_tables = %{ $params{nested_tables} || {} };
    for my $t (keys %nested_tables) {
        my $found =  $class->find_class($t) or die "could not find class for base table $t";
        $found->nested_tables($nested_tables{$t});
    }
}

=item tables

Return a list of all tables

=cut

sub tables {
    return (keys %table2Class, keys %deftable2Class);
}

=item regex_for_tables

Create a regex that matches all the tables.

=cut

sub regex_for_tables {
    my $self = shift;
    # the reverse sort is necessary so that tables which
    # are prefixes to others match.  e.g. app, appgroup
    # see https://github.com/kraih/mojo/issues/183
    my $re = join '|', reverse sort $self->tables;
    return qr[$re];
}

=item plurals

Return a list of all plurals

=cut

sub plurals {
    return keys %plural2Class;
}

=item regex_for_plurals

Create a regex that matches all the plurals.

=cut

sub regex_for_plurals {
    my $self = shift;
    my $re = join '|', reverse sort $self->plurals;
    return qr[$re];
}

=item find_class

Given the name of a database table, return the object class associated
with it.  e.g.

    Rose::Planter->find_class("app");

If the table name ends in _def, the prefix may be used, e.g
these are equivalent :

    Rose::Planter->find_class("esdt_def");
    Rose::Planter->find_class("esdt");

Also, given the plural of the name of a database table, return the
manager class associated with it.

    Rose::Planter->find_class("esdts");
    Rose::Planter->find_class("apps");

=cut

sub find_class {
    my $class = shift;
    my $table = shift;
    return $table2Class{$table} || $deftable2Class{$table} || $plural2Class{$table};
}

=item find_object

Given a table and a primary or other unique key(s), find a load an object.

Return false if there is no object matching that key.

=cut

sub find_object {
    my $package = shift;
    my $table  = shift;
    my @keys   = @_;

    my $object_class = Rose::Planter->find_class($table) or die "could not find class for $table";
    return unless $object_class->can("meta");

    foreach my $keycols ([$object_class->meta->primary_key_column_names],
                         $object_class->meta->unique_keys_column_names) {
        next unless @keys == @$keycols;
        my $object = $object_class->new( mesh @$keycols, @keys );
        return $object if $object->load(speculative => 1,
                                        with => $object_class->nested_tables);
    }

    return;
}

=back

=head1 NOTES

This is a beta release.  The API is subject to change without notice.

=head1 BUGS

Currently only really used/tested against postgres.

=head1 TODO

Auto generate perl code for classes, and rebuild as needed, rather than
keeping all the classes in memory.

=cut

1;
