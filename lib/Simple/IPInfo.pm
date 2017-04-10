# ABSTRACT: Get IP/IPList Info (location, as number, etc)
package Simple::IPInfo;
require Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(
  get_ip_loc
  get_ip_as
  get_ipinfo
  get_ipc_info

  cidr_to_range
  append_table_ipinfo
  read_ipinfo
);
use utf8;
use Data::Validate::IP qw/is_ipv4 is_ipv6 is_public_ipv4/;
use SimpleR::Reshape;
use JSON;
use File::Spec;
use Net::CIDR qw/cidr2range/;
use Socket qw/inet_aton inet_ntoa/;
use Memoize;
memoize( 'read_ipinfo' );

our $DEBUG = 0;

our $VERSION = 0.10;

my ( $vol, $dir, $file ) = File::Spec->splitpath( __FILE__ );
our $IPINFO_LOC_F = File::Spec->catpath( $vol, $dir, "inet_loc.csv" );
our $IPINFO_AS_F  = File::Spec->catpath( $vol, $dir, "inet_as.csv" );

my @key = qw/country prov isp country_code prov_code isp_code as/;
our %UNKNOWN = map { $_ => '' } @key;
our %ERROR   = map { $_ => 'error' } @key;
our %LOCAL   = map { $_ => 'local' } @key;

sub cidr_to_range {
  my ( $cidr, %opt ) = @_;
  $opt{inet} //= 1;

  my ( $addr_range ) = cidr2range( $cidr );
  my @addr = split /-/, $addr_range;
  return @addr unless ( $opt{inet} );

  my @inet = map { unpack( 'N', inet_aton( $_ ) ) } @addr;
  return @inet;
}

sub append_table_ipinfo {
    my ( $arr, $id, %o ) = @_;
    $o{ipinfo_file}  ||= $IPINFO_LOC_F;
    $o{ipinfo_names} ||= [qw/country prov isp country_code prov_code isp_code/];

    my $ip_info = get_ipinfo($arr, 
        in_sub => sub { return $_[0][$id] }, 
        use_ip_c => 1,  
        %o);

    read_table(
        $arr, %o,
        conv_sub => sub {
            my ( $r ) = @_;

            my $ip = $r->[$id];
            my $ip_c = $ip;
            $ip_c=~s/\.\d+$/.0/;

            my $dr = $ip_info->{$ip} || $ip_info->{$ip_c} || \%UNKNOWN;

            $dr->{$_} ||= '' for @{ $o{ipinfo_names} };
            [ @$r, @{ $dr }{ @{ $o{ipinfo_names} } } ];
        } );
} ## end sub append_table_ipinfo

sub inet_to_ip {
    my ($inet) = @_;
    return inet_ntoa(pack('N',$inet));
}

sub ip_to_inet {
    my ( $ip ) = @_;
    return (-1, \%ERROR) unless(is_ip($ip));
    my $inet = unpack( "N", inet_aton( $ip ) );
    return ($inet, \%LOCAL) unless(is_public_ip($ip));
    return $inet;
}

sub calc_ip_inet_list {
    my ( $ip_list, %opt ) = @_;

    $opt{in_sub} //= sub { return ref($_[0]) eq 'ARRAY' ? $_[0][0] : $_[0] };
    my @ip_inet = map { $opt{in_sub}->($_) } @$ip_list;

    if( $ip_inet[0]=~/^\d+$/){
        @ip_inet = map { my $ip = inet_to_ip($_); [ $ip, ip_to_inet($ip) ] } @ip_inet;
    }else {
        @ip_inet = map { [ $_, ip_to_inet($_) ] } @ip_inet;
    }

    if ( $opt{use_ip_c} ) {
        $_->[0]=~s/\.\d+$/.0/ for @ip_inet;
    }

    @ip_inet = sort { $a->[1] <=> $b->[1] } @ip_inet;
    return \@ip_inet;
}

sub get_ip_as {
  my ( $ip_list, %opt ) = @_;
  $opt{ipinfo_file} = $IPINFO_AS_F;
  return get_ipinfo( $ip_list, %opt );
}

sub get_ip_loc {
  my ( $ip_list, %opt ) = @_;
  $opt{ipinfo_file} = $IPINFO_LOC_F;
  return get_ipinfo( $ip_list, %opt );
}

sub get_ipc_info {
  my ( $ip, $info ) = @_;
  my $ip_c = $ip;
  $ip_c =~ s/\.\d+$/.0/;
  return $info->{$ip_c};
}

sub get_ipinfo {
    # large amount ip can use this function
    # ip array ref => ( ip => { country,prov,isp,country_code,prov_code,isp_code } )
    my ( $ip_list, %opt ) = @_;

    my $ip_inet = calc_ip_inet_list( $ip_list, %opt );

    my %result;
    my $res_sub = $opt{result_sub} // sub { my ($ip, $inet, $rr) = @_; $result{$ip} = $rr; $result{$inet}=$rr; };

    my $ip_info = read_ipinfo( $opt{ipinfo_file} );
    my $n = $#$ip_info;

    my ( $i, $r ) = ( 0, $ip_info->[0] );
    my ( $s, $e ) = @{$r}{qw/s e/};

    for my $x ( 0 .. $#$ip_inet ) {
        my ( $ip, $inet, $rr ) = @{$ip_inet->[$x]};
        print "\r$ip, $s, $e, $inet" if ( $DEBUG );

        if ( $rr ) {
            $res_sub->($ip, $inet, $rr);
            next;
        } elsif ( $inet < $s or $i > $n ) {
            $res_sub->($ip, $inet, \%UNKNOWN);
            next;
        }

        while ( $inet > $e and $i < $n ) {
            $i++;
            $r = $ip_info->[$i];
            ( $s, $e ) = @{$r}{qw/s e/};
        }

        if ( $inet >= $s and $inet <= $e and $i <= $n ) {
            $res_sub->($ip, $inet, $r);
        }
    } ## end for my $x ( @{$ip_inet}...)

    print "\n" if ( $DEBUG );

    return \%result;
} ## end sub get_ipinfo

sub read_ipinfo {
  my ( $f, $charset ) = @_;
  $f ||= $IPINFO_LOC_F;
  $charset ||= 'utf8';

  #local $/;
  my @d;
  open my $fh, "<:$charset", $f;
  chomp( my $h = <$fh> );
  my @head = split /,/, $h;
  while ( my $c = <$fh> ) {
    chomp( $c );
    my @line = split /,/, $c;
    my %k = map { $head[$_] => $line[$_] } ( 0 .. $#head );
    push @d, \%k;
  }
  close $fh;
  return \@d;
} ## end sub read_ipinfo

sub is_ip {
  my ( $ip ) = @_;
  return 1 if ( is_ipv4( $ip ) );
  return 1 if ( is_ipv6( $ip ) );
  return;
}

sub is_public_ip {
  my ( $ip ) = @_;
  return 1 if ( is_public_ipv4( $ip ) );
  return;
}

1;
