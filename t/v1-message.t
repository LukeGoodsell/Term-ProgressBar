# (X)Emacs mode: -*- cperl -*-

use strict;

=head1 Unit Test Package for Term::ProgressBar

This package tests the basic functionality of Term::ProgressBar.

=cut

use Data::Dumper qw( Dumper );
use FindBin      qw( $Bin );
use Test::More tests => 8;

use lib $Bin;
use test qw( evcheck );

use constant MESSAGE1 => 'Walking on the Milky Way';

=head2 Test 1: compilation

This test confirms that the test script and the modules it calls compiled
successfully.

=cut

use_ok 'Term::ProgressBar';


Term::ProgressBar->__force_term (50);

# -------------------------------------

=head2 Tests 2--8: Count 1-10

Create a progress bar with 10 things, and a name 'bob'.
Update it it from 1 to 10.

(1) Check no exception thrown on creation
(2) Check no exception thrown on update (1..5)
(3) Check no exception thrown on message send
(4) Check no exception thrown on update (6..10)
(5) Check message output.
(5) Check bar is complete
(6) Check bar number is 100%

=cut
use Capture::Tiny qw(capture);

my ($out, $err) = capture {
  my $p;
  ok (evcheck(sub { $p = Term::ProgressBar->new('bob', 10); },
              'Count 1-10 (1)' ),
      'Count 1-10 (1)');
  ok (evcheck(sub { $p->update($_) for 1..5  }, 'Count 1-10 (2)' ),
      'Count 1-10 (2)');
  ok (evcheck(sub { $p->message(MESSAGE1)    }, 'Count 1-10 (3)' ),
      'Count 1-10 (3)');
  ok (evcheck(sub { $p->update($_) for 6..10 }, 'Count 1-10 (4)' ),
      'Count 1-10 (4)');
};
print $out;

  $err =~ s!^.*\r!!gm;
  print STDERR "ERR:\n$err\nlength: ", length($err), "\n"
    if $ENV{TEST_DEBUG};

  my @lines = split /\n/, $err;

  is $lines[0], MESSAGE1;
  like $lines[-1], qr/bob:\s+\d+% \#+/,            'Count 1-10 (6)';
  like $lines[-1], qr/^bob:\s+100%/,               'Count 1-10 (7)';
