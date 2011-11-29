# (X)Emacs mode: -*- cperl -*-

package test;

=head1 NAME

test - tools for helping in test suites (not including running externalprograms).

=head1 SYNOPSIS

  use FindBin               1.42 qw( $Bin );
  use Test                  1.13 qw( ok plan );

  BEGIN { unshift @INC, $Bin };

  use test                  qw(   evcheck runcheck );

  BEGIN {
    plan tests  => 3,
         todo   => [],
         ;
  }

  ok evcheck(sub {
               open my $fh, '>', 'foo';
               print $fh "$_\n"
                 for 'Bulgaria', 'Cholet';
               close $fh;
             }, 'write foo'), 1, 'write foo';

  save_output('stderr', *STDERR{IO});
  warn 'Hello, Mum!';
  print restore_output('stderr');

=head1 DESCRIPTION

This package provides some variables, and sets up an environment, for test
scripts, such as those used in F<t/>.

This package does not including running external programs; that is provided by
C<test2.pm>.  This is so that suites not needing that can include only
test.pm, and so not require the presence of C<IPC::Run>.

Setting up the environment includes:

=over 4

=item Prepending F<blib/script> onto the path

=item Pushing the module F<lib/> dir onto the @INC var

For internal C<use> calls.

=item Changing directory to a temporary directory

To avoid cluttering the local dir, and/or allowing the local directory
structure to affect matters.

=item Cleaning up the temporary directory afterwards

Unless TEST_DEBUG is set in the environment.

=back

=cut

# ----------------------------------------------------------------------------

# Pragmas -----------------------------

use 5.00503;
use strict;
use vars qw( @EXPORT_OK );

# Inheritance -------------------------

use base qw( Exporter );

=head2 EXPORTS

The following symbols are exported upon request:

=over 4

=item compare

=item evcheck

=item only_files

=item save_output

=item restore_output

=item tmpnam

=item tempdir

=item find_exec

=back

=cut

@EXPORT_OK = qw( compare evcheck  
                 save_output restore_output tempdir tmpnam );

# Utility -----------------------------

use Carp                          qw( carp croak );
use Cwd                      2.01 qw( cwd );
use Env                           qw( PATH );
use Fatal                    1.02 qw( close open seek sysopen unlink );
use Fcntl                    1.03 qw( :DEFAULT );
use File::Basename                qw( basename );
use File::Compare          1.1002 qw( );
use File::Path             1.0401 qw( mkpath rmtree );
use File::Spec                0.6 qw( );
use FindBin                  1.42 qw( $Bin );
use POSIX                    1.02 qw( );
use Test                    1.122 qw( ok skip );

# ----------------------------------------------------------------------------

sub rel2abs {
  if ( File::Spec->file_name_is_absolute($_[0]) ) {
    return $_[0];
  } else {
    return catdir(cwd, $_[0]);
  }
}

sub catdir {
  File::Spec->catdir(@_);
}

sub catfile {
  File::Spec->catfile(@_);
}

sub updir {
  File::Spec->updir(@_);
}

sub min {
  croak "Can't min over 0 args!\n"
    unless @_;
  my $min = $_[0];
  for (@_[1..$#_]) {
    $min = $_
      if $_ < $min;
  }

  return $min;
}

# -------------------------------------
# PACKAGE CONSTANTS
# -------------------------------------

use constant BUILD_SCRIPT_DIR => => catdir $Bin, updir, qw( blib script );

sub find_exec {
  my ($exec) = @_;

  for (split /:/, $PATH) {
    my $try = catfile $_, $exec;
    return rel2abs($try)
      if -x $try;
  }
  return;
}

# -------------------------------------
# PACKAGE ACTIONS
# -------------------------------------

$PATH = join ':', BUILD_SCRIPT_DIR, split /:/, $PATH;

$_ = rel2abs($_)
  for @INC;

my $tmpdn = tempdir();
$| = 1;

mkpath $tmpdn;
die "Couldn't create temp dir: $tmpdn: $!\n"
  unless -r $tmpdn and -w $tmpdn and -x $tmpdn and -o $tmpdn and -d $tmpdn;

#@INC = map rel2abs($_), @INC;
chdir $tmpdn;

# -------------------------------------
# PACKAGE FUNCTIONS
# -------------------------------------

=head2 only_files

=over 4

=item ARGUMENTS

=over 4

=item expect

Arrayref of names of files to expect to exist.

=back

=item RETURNS

=over 4

=item ok

1 if exactly expected files exist, false otherwise.

=back

=back

=cut

sub only_files {
  my ($expect) = @_;

  local *MYDIR;
  opendir MYDIR, '.';
  my %files = map { $_ => 1 } readdir MYDIR;
  closedir MYDIR;

  my $ok = 1;

  for (@$expect, '.', '..') {
    if ( exists $files{$_} ) {
      delete $files{$_};
    } elsif ( ! -e $_ ) { # $_ might be absolute
      carp "File not found: $_\n"
        if $ENV{TEST_DEBUG};
      $ok = 0;
    }
  }

  for (keys %files) {
    carp "Extra file found: $_\n"
      if $ENV{TEST_DEBUG};
    $ok = 0;
  }

  if ( $ok ) {
    return 1;
  } else {
    return;
  }
}

# -------------------------------------

=head2 evcheck

Eval code, return status

=over 4

=item ARGUMENTS

=over 4

=item code

Coderef to eval

=item name

Name to use in error messages

=back

=item RETURNS

=over 4

=item okay

1 if eval was okay, 0 if not.

=back

=back

=cut

sub evcheck {
  my ($code, $name) = @_;

  my $ok = 0;

  eval {
    &$code;
    $ok = 1;
  }; if ( $@ ) {
    carp "Code $name failed: $@\n"
      if $ENV{TEST_DEBUG};
    $ok = 0;
  }

  return $ok;
}

# -------------------------------------

=head2 save_output

Redirect a filehandle to temporary storage for later examination.

=over 4

=item ARGUMENTS

=over 4

=item name

Name to store as (used in L<restore_output>)

=item filehandle

The filehandle to save

=back

=cut

# Map from names to saved filehandles.

# Values are arrayrefs, being filehandle that was saved (to restore), the
# filehandle being printed to in the meantime, and the original filehandle.
# This may be treated as a stack; to allow multiple saves... push & pop this
# stack.

my %grabs;

sub save_output {
  croak sprintf("%s takes 2 arguments\n", (caller 0)[3])
    unless @_ == 2;
  my ($name, $filehandle) = @_;

  my $tmpfh  = do { local *F; *F; };
  my $savefh = do { local *F; *F; };

  (undef, $tmpfh) = test::tmpnam();
  select((select($tmpfh), $| = 1)[0]);

  open $savefh, '>&' . fileno $filehandle
    or die "can't dup $name: $!";
  open $filehandle, '>&' . fileno $tmpfh
    or die "can't open $name to tempfile: $!";

  push @{$grabs{$name}}, $savefh, $tmpfh, $filehandle;
}

# -------------------------------------

=head2 restore_output

Restore a saved filehandle to its original state, return the saved output.

=over 4

=item ARGUMENTS

=over 4

=item name

Name of the filehandle to restore (as passed to L<save_output>).

=back

=item RETURNS

=over 4

=item saved_string

A single string being the output saved.

=back

=cut

sub restore_output {
  my ($name) = @_;

  croak "$name has not been saved\n"
    unless exists $grabs{$name};
  croak "All saved instances of $name have been restored\n"
    unless @{$grabs{$name}};
  my ($savefh, $tmpfh, $origfh) = splice @{$grabs{$name}}, -3;

  close $origfh
    or die "cannot close $name opened to tempfile: $!";
  open  $origfh, '>&' . fileno $savefh
    or die "cannot dup $name back again: $!";
  select((select($origfh), $| = 1)[0]);

  seek $tmpfh, 0, 0;
  local $/ = undef;
  my $string = <$tmpfh>;
  close $tmpfh;

  return $string;
}

sub _test_save_restore_output {
  warn "to stderr 1\n";
  save_output("stderr", *STDERR{IO});
  warn "Hello, Mum!";
  print 'SAVED:->:', restore_output("stderr"), ":<-\n";
  warn "to stderr 2\n";
}

# -------------------------------------

=head2 tmpnam

Very much like the one in L<POSIX> or L<File::Temp>, but does not get deleted
if TEST_DEBUG has SAVE in the value.

=over 4

=item ARGUMENTS

=over 4

=item name

I<Optional>.  If defined, a name by which to refer to the tmpfile in user
messages.

=back

=item RETURNS

=over 4

=item filename

Name of temporary file.

=item fh

Open filehandle to temp file, in r/w mode.  Only created & returned in list
context.

=back

=back

=cut

my @tmpfns;

BEGIN {
  my $savewarn = $SIG{__WARN__};
  # Subvert bizarre (& incorrect) subroutine redefined errors in 5.005_03
  local $SIG{__WARN__} =
    sub {
      $savewarn->(@_)
        if defined $savewarn                        and
           UNIVERSAL::isa($savewarn,'CODE')         and
           $_[0] !~ /^Subroutine tmpnam redefined/;
    };

  *tmpnam = sub {
    my $tmpnam = POSIX::tmpnam;

    if (@_) {
      push @tmpfns, [ $tmpnam, $_[0] ];
    } else {
      push @tmpfns, $tmpnam;
    }

    if (wantarray) {
      sysopen my $tmpfh, $tmpnam, O_RDWR | O_CREAT | O_EXCL;
      return $tmpnam, $tmpfh;
    } else {
      return $tmpnam;
    }
  }
}

END {
  if ( defined $ENV{TEST_DEBUG} and $ENV{TEST_DEBUG} =~ /\bSAVE\b/ ) {
    for (@tmpfns) {
      if ( ref $_ ) {
        printf "Used temp file: %s (%s)\n", @$_;
      } else {
        print "Used temp file: $_\n";
      }
    }
  } else {
    unlink map((ref $_ ? $_->[0] : $_), @tmpfns)
      if @tmpfns;
  }
}

# -------------------------------------

=head2 tempdir

Very much like the one in L<POSIX> or L<File::Temp>, but does not get deleted
if TEST_DEBUG has SAVE in the value (does get deleted otherwise).

=over 4

=item ARGUMENTS

I<None>

=item RETURNS

=over 4

=item name

Name of temporary dir.

=back

=back

=cut

my @tmpdirs;
sub tempdir {
  my $tempdir = POSIX::tmpnam;
  mkdir $tempdir, 0700
    or die "Failed to create temporary directory $tempdir: $!\n";

  if (@_) {
    push @tmpdirs, [ $tempdir, $_[0] ];
  } else {
    push @tmpdirs, $tempdir;
  }

  return $tempdir;
}

END {
  for (@tmpdirs) {
    if ( ref $_ ) {
      if ( defined $ENV{TEST_DEBUG} and $ENV{TEST_DEBUG} =~ /\bSAVE\b/ ) {
        printf "Used temp dir: %s (%s)\n", @$_;
      } else {
        # Solaris gets narky about removing the pwd.
        chdir File::Spec->rootdir;
        rmtree $_->[0];
      }
    } else {
      if ( defined $ENV{TEST_DEBUG} and $ENV{TEST_DEBUG} =~ /\bSAVE\b/ ) {
        print "Used temp dir: $_\n";
      } else {
        # Solaris gets narky about removing the pwd.
        chdir File::Spec->rootdir;
        rmtree $_;
      }
    }
  }
}

# -------------------------------------

=head2 compare

  compare(+{ fn1 => $fn1, fn2 => $fn2, gzip => 1 });

This performs one test.

=over 4

=item ARGUMENTS

A single argument is taken, considered as a hash ref, with the following keys:

In TEST_DEBUG mode, if the files do not compare equal, outputs file info on
STDERR.

=over 4

=item fn1

B<Mandatory>  File to compare

=item fn2

B<Mandatory>  File to compare

=item name

B<Mandatory>  Test name

=item sort

B<Optional> sort files prior to comparison.  Requires the C<sort> command to
be on C<$PATH> (else skips).

=item gunzip

B<Optional> gunzip files prior to comparison.  Requires the C<gzip> command to
be on C<$PATH> (else skips).  gzip occurs prior to any sort.

=item untar

B<Optional> untar files prior to comparison.  Requires the C<tar> command to
be on C<$PATH> (else skips).  any gzip occurs prior to any tar.  Tar files are
considered equal if they each contain the same filenames & each file contained
is equal.  If the sort flag is present, each file is sorted prior to comparison.

=back

=back

=cut

# return codes and old-style call semantics left for backwards compatibility
BEGIN {
  my $savewarn = $SIG{__WARN__};
  # Subvert bizarre (& incorrect) subroutine redefined errors in 5.005_03
  local $SIG{__WARN__} =
    sub {
      $savewarn->(@_)
        if defined $savewarn                        and
           UNIVERSAL::isa($savewarn,'CODE')         and
           $_[0] !~ /^Subroutine compare redefined/;
    };

  *compare = sub {
    my ($fn1, $fn2, $sort) = @_;
    my ($gzip, $tar, $name);
    my $notest = 1;

    if ( @_ == 1 and UNIVERSAL::isa($_[0], 'HASH') ) {
      ($fn1, $fn2, $name, $sort, $gzip, $tar, $notest) =
        @{$_[0]}{qw( fn1 fn2 name sort gunzip untar notest )};
      my @missing = grep ! defined $_[0]->{$_}, qw( fn1 fn2 name );
      carp "Missing mandatory key(s): " . join(', ', @missing) . "\n"
        if @missing;
    }

    my ($name1, $name2) = ($fn1, $fn2);

    for ( grep ! defined, $fn1, $fn2 ) {
      carp 'Usage: compare({fn1 => $fn1, fn2 => $fn2, name => "some name"})' ."\n"
          if $ENV{TEST_DEBUG};
      ok 0, 1, $name
        unless $notest;
      return -8;
    }

    {
      my $err = 0;

      for (0..1) {
        my $fn = ($name1, $name2)[$_];
        if ( ! -e $fn ) {
          carp "Does not exist: $fn\n"
            if $ENV{TEST_DEBUG};
          $err |= 2 ** $_;
        } elsif ( ! -r $fn ) {
          carp "Cannot read: $fn\n"
            if $ENV{TEST_DEBUG};
          $err |= 2 ** $_;
        }
      }

      if ( $err ) {
        ok 0, 1, $name
          unless $notest;
        return -$err;
      }
    }

    if ( $gzip ) {
      unless ( find_exec('gzip') ) {
        print "ok # Skip gzip not found in path\n";
        return -16;
      }

      my $tmp1 = tmpnam;
      my $tmp2 = tmpnam;
      system "gzip $fn1 -cd > $tmp1"
        and croak "gzip $fn1 failed: $?\n";
      system "gzip $fn2 -cd > $tmp2"
        and croak "gzip $fn2 failed: $?\n";
      ($fn1, $fn2) = ($tmp1, $tmp2);
    }

    if ( $tar ) {
      unless ( find_exec('tar') ) {
        print "ok # Skip tar not found in path\n";
        return -16;
      }

      local $/ = "\n";
      chomp (my @list1 = sort qx( tar tf $fn1 ));
      croak "tar tf $fn1 failed with wait status: $?\n"
        if $?;
      chomp(my @list2 = sort qx( tar tf $fn2 ));
      croak "tar tf $fn2 failed with wait status: $?\n"
        if $?;

      if ( @list2 > @list1 ) {
        carp
          sprintf("More files (%d) in $name2 than $name1 (%d)\n",
                  scalar @list2, scalar @list1)
          if $ENV{TEST_DEBUG};
        ok @list1, @list2, $name
          unless $notest;
        return 0;
      } elsif ( @list1 > @list2 ) {
        carp
          sprintf("More files (%d) in $name1 than $name2 (%d)\n",
                  scalar @list1, scalar @list2)
          if $ENV{TEST_DEBUG};
        ok @list1, @list2, $name
          unless $notest;
        return 0;
      }

      for (my $i = 0; $i < @list1; $i++) {
        if ( $list1[$i] lt $list2[$i] ) {
          carp "File $list1[$i] is present in $name1 but not $name2\n"
            if $ENV{TEST_DEBUG};
          ok $list1[$i], $list2[$i], $name
            unless $notest;
          return 0;
        } elsif ( $list1[$i] gt $list2[$i] ) {
          carp "File $list2[$i] is present in $name2 but not $name1\n"
            if $ENV{TEST_DEBUG};
          ok $list2[$i], $list1[$i], $name
            unless $notest;
          return 0;
        }
      }

      for my $fn (@list1) {
        my $tmp1 = tmpnam;
        my $tmp2 = tmpnam;
        system "tar -xf $fn1 -O $fn > $tmp1"
          and croak "tar -xf $fn1 -O $fn failed: $?\n";
        system "tar -xf $fn2 -O $fn > $tmp2"
          and croak "tar -xf $fn2 -O $fn failed: $?\n";
        my $ok = compare({ fn1    => $tmp1,
                           fn2    => $tmp2,
                           sort   => $sort,
                           notest => 1,
                           name   =>
                             qq'Subcheck file "$fn" for compare $name1, $name2',
                         });
        unless ( $ok >= 1 ) {
          carp qq'Difference found testing file "$fn" in tars $name1 ($tmp1), $name2 ($tmp2)\n'
            if $ENV{TEST_DEBUG};
          ok 0, 1, $name
            unless $notest;
          return 0;
        }
      }

      ok 1, 1, $name
        unless $notest;
      return 1;
    }

    if ( $sort ) {
      unless ( find_exec('sort') ) {
        print "ok # Skip sort not found in path\n";
        return -16;
      }

      my $tmp1 = tmpnam;
      my $tmp2 = tmpnam;
      system sort => $fn1, -o => $tmp1
        and croak "Sort $fn1 failed: $?\n";
      system sort => $fn2, -o => $tmp2
        and croak "Sort $fn2 failed: $?\n";
      ($fn1, $fn2) = ($tmp1, $tmp2);
    }

    unless ( File::Compare::compare($fn1, $fn2) ) {
      ok 1, 1, $name
        unless $notest;
      return 1;
    }

    if ( $ENV{TEST_DEBUG} ) {
      my $pid = fork;
      die "Fork failed: $!\n"
        unless defined $pid;

      if ( $pid ) { # Parent
        my $waitpid = waitpid($pid, 0);
        die "Waitpid got: $waitpid (expected $pid)\n"
          unless $waitpid == $pid;
      } else { # Child
        open *STDOUT{IO}, ">&" . fileno STDERR;
        # Uniquify file names
        my @args = keys %{+{ map {;$_=>1} $name1, $name2, $fn1, $fn2 }};
        exec qw(ls -l), @args;
      }

      my $fh1 = IO::File->new($fn1, O_RDONLY)
        or die "Couldn't open $fn1: $!\n";
      my $fh2 = IO::File->new($fn2, O_RDONLY)
        or die "Couldn't open $fn2: $!\n";

      local $/ = "\n";

      my $found = 0;
      while ( ! $found and my $line1 = <$fh1> ) {
        my $line2 = <$fh2>;
        if ( ! defined $line2 ) {
          print STDERR "$fn2 ended at line: $.\n";
          $found = 1;
        } elsif ( $line2 ne $line1 ) {
          my $maxlength = max(map length($_), $line1, $line2);
          my $minlength = min(map length($_), $line1, $line2);

          my @diffchars = grep(substr($line1, $_, 1) ne substr($line2, $_, 1),
                               0..$minlength-1);
          my $diff = ' ' x $minlength;
          substr($diff, $_, 1) = '|'
            for @diffchars;

          my @extrachars, map((length($line1) > length($line2) ? '^' : 'v'),
                              $minlength..$maxlength-1);

          $diff = join '', $diff, @extrachars;

          my $diff_count  = @diffchars;
          my $extra_count = @extrachars;

          print STDERR <<"END";
Difference at line $. ($diff_count characters differ) (top line is $extra_count chars longer):
$name1:
-->$line1<--
   $diff
-->$line2<--
$name2:
Differing characters at positions @{[join ',',@diffchars]} (zero-based)
END
          $found = 1;
        }
      }

      if ( ! $found ) {
        my $line2 = <$fh2>;
        if ( defined $line2 ) {
          print STDERR "$name1 ended before line: $.\n";
        } else {
          print STDERR "Difference between $name1, $name2 not found!\n";
        }
      }

      close $fh1;
      close $fh2;
    }

    ok 0, 1, $name
      unless $notest;
    return 0;
  }
}

# -------------------------------------

=head2 find_exec

=over 4

=item ARGUMENTS

=over 4

=item proggie

The name of the program

=back

=item RETURNS

=over 4

=item path

The path to the first executable file with the given name on C<$PATH>.  Or
nothing, if no such file exists.

=back

=back

=cut

# defined further up to use in constants

# ----------------------------------------------------------------------------

=head1 EXAMPLES

Z<>

=head1 BUGS

Z<>

=head1 REPORTING BUGS

Email the author.

=head1 AUTHOR

Martyn J. Pearce C<fluffy@cpan.org>

=head1 COPYRIGHT

Copyright (c) 2001, 2002, 2004 Martyn J. Pearce.  This program is free
software; you can redistribute it and/or modify it under the same terms as
Perl itself.

=head1 SEE ALSO

Z<>

=cut

1; # keep require happy.

__END__
