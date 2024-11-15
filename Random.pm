# String::Random - Generates a random string from a pattern
# Copyright (C) 1999-2006 Steven Pritchard <steve@silug.org>
#
# This program is free software; you can redistribute it
# and/or modify it under the same terms as Perl itself.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# $Id: Random.pm,v 1.4 2006/09/21 17:34:07 steve Exp $

package Plugins::SqueezeCloud::Random;

require 5.006_001;

use strict;
use warnings;

use Carp;
use parent qw(Exporter);

our %EXPORT_TAGS = (
    'all' => [
        qw(
            &random_string
            &random_regex
            )
    ]
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

# These are the various character sets.
my @upper  = ( 'A' .. 'Z' );
my @lower  = ( 'a' .. 'z' );
my @digit  = ( '0' .. '9' );
my @punct  = map {chr} ( 33 .. 47, 58 .. 64, 91 .. 96, 123 .. 126 );
my @any    = ( @upper, @lower, @digit, @punct );
my @salt   = ( @upper, @lower, @digit, '.', '/' );
my @binary = map {chr} ( 0 .. 255 );

# What's important is how they relate to the pattern characters.
# These are the old patterns for randpattern/random_string.
my %old_patterns = (
    'C' => [@upper],
    'c' => [@lower],
    'n' => [@digit],
    '!' => [@punct],
    '.' => [@any],
    's' => [@salt],
    'b' => [@binary],
);

# These are the regex-based patterns.
my %patterns = (

    # These are the regex-equivalents.
    '.'  => [@any],
    '\d' => [@digit],
    '\D' => [ @upper, @lower, @punct ],
    '\w' => [ @upper, @lower, @digit, '_' ],
    '\W' => [ grep  { $_ ne '_' } @punct ],
    '\s' => [ q{ }, "\t" ],                  # Would anything else make sense?
    '\S' => [ @upper, @lower, @digit, @punct ],

    # These are translated to their double quoted equivalents.
    '\t' => ["\t"],
    '\n' => ["\n"],
    '\r' => ["\r"],
    '\f' => ["\f"],
    '\a' => ["\a"],
    '\e' => ["\e"],
);

# This is used for cache of parsed range patterns in %regch
my %parsed_range_patterns = ();

# These characters are treated specially in randregex().
my %regch = (
    '\\' => sub {
        my ( $self, $ch, $chars, $string ) = @_;
        if ( @{$chars} ) {
            my $tmp = shift( @{$chars} );
            if ( $tmp eq 'x' ) {

                # This is supposed to be a number in hex, so
                # there had better be at least 2 characters left.
                $tmp = shift( @{$chars} ) . shift( @{$chars} );
                push( @{$string}, [ chr( hex($tmp) ) ] );
            }
            elsif ( $tmp =~ /[0-7]/ ) {
                carp 'octal parsing not implemented.  treating literally.';
                push( @{$string}, [$tmp] );
            }
            elsif ( defined( $patterns{"\\$tmp"} ) ) {
                $ch .= $tmp;
                push( @{$string}, $patterns{$ch} );
            }
            else {
                if ( $tmp =~ /\w/ ) {
                    carp "'\\$tmp' being treated as literal '$tmp'";
                }
                push( @{$string}, [$tmp] );
            }
        }
        else {
            croak 'regex not terminated';
        }
    },
    '.' => sub {
        my ( $self, $ch, $chars, $string ) = @_;
        push( @{$string}, $patterns{$ch} );
    },
    '[' => sub {
        my ( $self, $ch, $chars, $string ) = @_;
        my @tmp;
        while ( defined( $ch = shift( @{$chars} ) ) && ( $ch ne ']' ) ) {
            if ( ( $ch eq '-' ) && @{$chars} && @tmp ) {
                my $begin_ch = $tmp[-1];
                $ch = shift( @{$chars} );
                my $key = "$begin_ch-$ch";
                if ( defined( $parsed_range_patterns{$key} ) ) {
                    push( @tmp, @{ $parsed_range_patterns{$key} } );
                }
                else {
                    my @chs;
                    for my $n ( ( ord($begin_ch) + 1 ) .. ord($ch) ) {
                        push @chs, chr($n);
                    }
                    $parsed_range_patterns{$key} = \@chs;
                    push @tmp, @chs;
                }
            }
            else {
                carp "'$ch' will be treated literally inside []"
                    if ( $ch =~ /\W/ );
                push( @tmp, $ch );
            }
        }
        croak 'unmatched []' if ( $ch ne ']' );
        push( @{$string}, \@tmp );
    },
    '*' => sub {
        my ( $self, $ch, $chars, $string ) = @_;
        unshift( @{$chars}, split( //, '{0,}' ) );
    },
    '+' => sub {
        my ( $self, $ch, $chars, $string ) = @_;
        unshift( @{$chars}, split( //, '{1,}' ) );
    },
    '?' => sub {
        my ( $self, $ch, $chars, $string ) = @_;
        unshift( @{$chars}, split( //, '{0,1}' ) );
    },
    '{' => sub {
        my ( $self, $ch, $chars, $string ) = @_;
        my $closed;
    CLOSED:
        for my $c ( @{$chars} ) {
            if ( $c eq '}' ) {
                $closed = 1;
                last CLOSED;
            }
        }
        if ($closed) {
            my $tmp;
            while ( defined( $ch = shift( @{$chars} ) ) && ( $ch ne '}' ) ) {
                croak "'$ch' inside {} not supported" if ( $ch !~ /[\d,]/ );
                $tmp .= $ch;
            }
            if ( $tmp =~ /,/ ) {
                if ( my ( $min, $max ) = $tmp =~ /^(\d*),(\d*)$/ ) {
                    if ( !length($min) ) { $min = 0 }
                    if ( !length($max) ) { $max = $self->{'_max'} }
                    croak "bad range {$tmp}" if ( $min > $max );
                    if ( $min == $max ) {
                        $tmp = $min;
                    }
                    else {
                        $tmp = $min + $self->{'_rand'}( $max - $min + 1 );
                    }
                }
                else {
                    croak "malformed range {$tmp}";
                }
            }
            if ($tmp) {
                my $prev_ch = $string->[-1];

                push @{$string}, ( ($prev_ch) x ( $tmp - 1 ) );
            }
            else {
                pop( @{$string} );
            }
        }
        else {
            # { isn't closed, so treat it literally.
            push( @{$string}, [$ch] );
        }
    },
);

# Default rand function
sub _rand {
    my ($max) = @_;
    return int rand $max;
}

sub new {
    my ( $proto, @args ) = @_;
    my $class = ref($proto) || $proto;
    my $self;
    $self = {%old_patterns};    # makes $self refer to a copy of %old_patterns
    my %args = ();
    if (@args) { %args = @args }
    if ( defined( $args{'max'} ) ) {
        $self->{'_max'} = $args{'max'};
    }
    else {
        $self->{'_max'} = 10;
    }
    if ( defined( $args{'rand_gen'} ) ) {
        $self->{'_rand'} = $args{'rand_gen'};
    }
    else {
        $self->{'_rand'} = \&_rand;
    }
    return bless( $self, $class );
}

# Returns a random string for each regular expression given as an
# argument, or the strings concatenated when used in a scalar context.
sub randregex {
    my $self = shift;
    croak 'called without a reference' if ( !ref($self) );

    my @strings = ();

    while ( defined( my $pattern = shift ) ) {
        my $ch;
        my @string = ();
        my $string = q{};

        # Split the characters in the pattern
        # up into a list for easier parsing.
        my @chars = split( //, $pattern );

        while ( defined( $ch = shift(@chars) ) ) {
            if ( defined( $regch{$ch} ) ) {
                $regch{$ch}->( $self, $ch, \@chars, \@string );
            }
            elsif ( $ch =~ /[\$\^\*\(\)\+\{\}\]\|\?]/ ) {

                # At least some of these probably should have special meaning.
                carp "'$ch' not implemented.  treating literally.";
                push( @string, [$ch] );
            }
            else {
                push( @string, [$ch] );
            }
        }

        foreach my $ch (@string) {
            $string .= $ch->[ $self->{'_rand'}( scalar( @{$ch} ) ) ];
        }

        push( @strings, $string );
    }

    return wantarray ? @strings : join( q{}, @strings );
}

# For compatibility with an ancient version, please ignore...
sub from_pattern {
    my ( $self, @args ) = @_;
    croak 'called without a reference' if ( !ref($self) );

    return $self->randpattern(@args);
}

sub randpattern {
    my $self = shift;
    croak 'called without a reference' if ( !ref($self) );

    my @strings = ();

    while ( defined( my $pattern = shift ) ) {
        my $string = q{};

        for my $ch ( split( //, $pattern ) ) {
            if ( defined( $self->{$ch} ) ) {
                $string .= $self->{$ch}
                    ->[ $self->{'_rand'}( scalar( @{ $self->{$ch} } ) ) ];
            }
            else {
                croak qq(Unknown pattern character "$ch"!);
            }
        }
        push( @strings, $string );
    }

    return wantarray ? @strings : join( q{}, @strings );
}

sub get_pattern {
  my ( $self, $name ) = @_;
  return $self->{ $name };
}

sub set_pattern {
  my ( $self, $name, $charset ) = @_;
  $self->{ $name } = $charset;
}

sub random_regex {
    my (@args) = @_;
    my $foo = Plugins::SqueezeCloud::Random->new;
    return $foo->randregex(@args);
}

sub random_string {
    my ( $pattern, @list ) = @_;

    my $foo = Plugins::SqueezeCloud->new;

    for my $n ( 0 .. $#list ) {
        $foo->{$n} = [ @{ $list[$n] } ];
    }

    return $foo->randpattern($pattern);
}

1;
__END__

=encoding utf8

=head1 NAME

String::Random - Perl module to generate random strings based on a pattern

=head1 SYNOPSIS

    use String::Random;
    my $string_gen = String::Random->new;
    print $string_gen->randregex('\d\d\d'); # Prints 3 random digits
    # Prints 3 random printable characters
    print $string_gen->randpattern("...");

I<or>

    use String::Random qw(random_regex random_string);
    print random_regex('\d\d\d'); # Also prints 3 random digits
    print random_string("...");   # Also prints 3 random printable characters

=head1 DESCRIPTION

This module makes it trivial to generate random strings.

As an example, let's say you are writing a script that needs to generate a
random password for a user.  The relevant code might look something like
this:

    use String::Random;
    my $pass = String::Random->new;
    print "Your password is ", $pass->randpattern("CCcc!ccn"), "\n";

This would output something like this:

  Your password is UDwp$tj5

B<NOTE!!!>: currently, C<String::Random> defaults to Perl's built-in predictable
random number generator so the passwords generated by it are insecure.  See the
C<rand_gen> option to C<String::Random> constructor to specify a more secure
random number generator.  There is no equivalent to this in the procedural
interface, you must use the object-oriented interface to get this
functionality.

If you are more comfortable dealing with regular expressions, the following
code would have a similar result:

  use String::Random;
  my $pass = String::Random->new;
  print "Your password is ",
      $pass->randregex('[A-Z]{2}[a-z]{2}.[a-z]{2}\d'), "\n";

=head2 Patterns

The pre-defined patterns (for use with C<randpattern()> and C<random_pattern()>)
are as follows:

  c        Any Latin lowercase character [a-z]
  C        Any Latin uppercase character [A-Z]
  n        Any digit [0-9]
  !        A punctuation character [~`!@$%^&*()-_+={}[]|\:;"'.<>?/#,]
  .        Any of the above
  s        A "salt" character [A-Za-z0-9./]
  b        Any binary data

These can be modified, but if you need a different pattern it is better to
create another pattern, possibly using one of the pre-defined as a base.
For example, if you wanted a pattern C<A> that contained all upper and lower
case letters (C<[A-Za-z]>), the following would work:

  my $gen = String::Random->new;
  $gen->{'A'} = [ 'A'..'Z', 'a'..'z' ];

I<or>

  my $gen = String::Random->new;
  $gen->{'A'} = [ @{$gen->{'C'}}, @{$gen->{'c'}} ];

I<or>

  my $gen = String::Random->new;
  $gen->set_pattern(A => [ 'A'..'Z', 'a'..'z' ]);

The random_string function, described below, has an alternative interface
for adding patterns.

=head2 Methods

=over 8

=item new

=item new max =E<gt> I<number>

=item new rand_gen =E<gt> I<sub>

Create a new String::Random object.

Optionally a parameter C<max> can be included to specify the maximum number
of characters to return for C<*> and other regular expression patterns that
do not return a fixed number of characters.

Optionally a parameter C<rand_gen> can be included to specify a subroutine
coderef for generating the random numbers used in this module. The coderef
must accept one argument C<max> and return an integer between 0 and C<max - 1>.
The default rand_gen coderef is

 sub {
     my ($max) = @_;
     return int rand $max;
 }

=item randpattern LIST

The randpattern method returns a random string based on the concatenation
of all the pattern strings in the list.

It will return a list of random strings corresponding to the pattern
strings when used in list context.

=item randregex LIST

The randregex method returns a random string that will match the regular
expression passed in the list argument.

Please note that the arguments to randregex are not real regular
expressions.  Only a small subset of regular expression syntax is actually
supported.  So far, the following regular expression elements are
supported:

  \w    Alphanumeric + "_".
  \d    Digits.
  \W    Printable characters other than those in \w.
  \D    Printable characters other than those in \d.
  .     Printable characters.
  []    Character classes.
  {}    Repetition.
  *     Same as {0,}.
  ?     Same as {0,1}.
  +     Same as {1,}.

Regular expression support is still somewhat incomplete.  Currently special
characters inside [] are not supported (with the exception of "-" to denote
ranges of characters).  The parser doesn't care for spaces in the "regular
expression" either.

=item get_pattern STRING

Return a pattern given a name.

  my $gen = String::Random->new;
  $gen->get_pattern('C');

(Added in version 0.32.)

=item set_pattern STRING ARRAYREF

Add or redefine a pattern given a name and a character set.

  my $gen = String::Random->new;
  $gen->set_pattern(A => [ 'A'..'Z', 'a'..'z' ]);

(Added in version 0.32.)

=item from_pattern

B<IGNORE!> - for compatibility with an old version. B<DO NOT USE!>

=back

=head2 Functions

=over 8

=item random_string PATTERN,LIST

=item random_string PATTERN

When called with a single scalar argument, random_string returns a random
string using that scalar as a pattern.  Optionally, references to lists
containing other patterns can be passed to the function.  Those lists will
be used for 0 through 9 in the pattern (meaning the maximum number of lists
that can be passed is 10).  For example, the following code:

    print random_string("0101",
                        ["a", "b", "c"],
                        ["d", "e", "f"]), "\n";

would print something like this:

    cebd

=item random_regex REGEX_IN_STRING

Prints a string for the regular expression given as the string. See the
synposis for example.

=back

=head1 BUGS

This is Bug Free™ code.  (At least until somebody finds one…)

Please report bugs here:

L<https://rt.cpan.org/Public/Dist/Display.html?Name=String-Random> .

=head1 AUTHOR

Original Author: Steven Pritchard C<< steve@silug.org >>

Now maintained by: Shlomi Fish ( L<http://www.shlomifish.org/> ).

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

perl(1).

=cut

# vi: set ai et:
