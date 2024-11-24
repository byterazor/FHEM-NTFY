=head1 NAME

NTFY_TOPIC - "physical" client for ntfy.sh based servers to receive notifications from topics

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2024 by Dominik Meyer

This program is free software: you can redistribute it and/or modify it under the terms of the 
GNU General Public License as published by the Free Software Foundation, either version 3 of the 
License, or (at your option) any later version.

This module is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even 
the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. 
See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. 
If not, see <https://www.gnu.org/licenses/>.

=head1 DESCRIPTION

This module is the "physical" device to connect a topic on a ntfy compatible server with the NTFY_CLIENT.

=head1 AUTHORS

Dominik Meyer <dmeyer@federationhq.de>

=cut

package main;

# enforce strict and warnings mode
use strict;
use warnings;

# required for sending and receiving data from ntfy.sh
use LWP::UserAgent;
use HTTP::Request;
use URI;
use JSON;
use Text::ParseWords;
use HttpUtils;
use FHEM::Text::Unicode qw(:ALL);
use Data::Dumper;

# some module wide constansts
my $MODULE_NAME="NTFY-TOPIC";
my $VERSION    = '0.0.1';


use constant {
    LOG_CRITICAL        => 0,
    LOG_ERROR           => 1,
    LOG_WARNING         => 2,
    LOG_SEND            => 3,
    LOG_RECEIVE         => 4,
    LOG_DEBUG           => 5,

    PRIO_DEFAULT        => 3,
    PRIO_HIGH           => 5,
    PRIO_LOW            => 2
};

# NTFY logging method
sub NTFY_TOPIC_LOG
{
  my $verbosity = shift;
  my $msg       = shift;

  Log3 $MODULE_NAME, $verbosity, $MODULE_NAME . ":" . $msg;
}

# initialize the NTFY Topic Module
sub NTFY_TOPIC_Initialize
{
  my ($hash) = @_;
  
  $hash->{DefFn}      = 'NTFY_TOPIC_Define';
  $hash->{ReadFn}     = 'NTFY_TOPIC_Read';
  $hash->{WriteFn}    = 'NTFY_TOPIC_Write';
  $hash->{AttrFn}     = 'NTFY_TOPIC_Attr';
  $hash->{AttrList}   = $readingFnAttributes;
  $hash->{MatchList} = {"1:NTFY_CLIENT" => "^NTFY:.*"};

}

sub NTFY_TOPIC_Define 
{
    my ($hash, $define) = @_;

    # ensure we have something to parse
    if (!$define)
    {
      warn("$MODULE_NAME: no module definition provided");
      NTFY_TOPIC_LOG(LOG_ERROR,"no module definition provided");
      return;
    }

    # parse parameters into array and hash
    my($params, $h) = parseParams($define);

    my $token;
    my $topic;

    if ($params->[4])
    {
      $topic = $params->[4];
      $token = $params->[3]
    }
    else 
    {
      $topic = $params->[3];
    }

    my $name                        = makeDeviceName($params->[0]);

    $hash->{NAME}                   = $name;
    $hash->{SERVER}                 = $params->[2];
    $hash->{helper}{authString}     = $token;
    $hash->{TOPIC}                  = $topic;
    $hash->{Clients}                = "NTFY_CLIENT";
    $hash->{ClientsKeepOrder}       = 1;
    $hash->{STATE}                  = "unknown";
    $hash->{nextOpenDelay}          = 20;
    $modules{NTFY_TOPIC}{defptr}{$hash->{SERVER} . "_" . $hash->{TOPIC}} = $hash;

    $attr{$hash->{NAME}}{room} = 'hidden';
    
    my $useSSL = 0;
    if ($hash->{SERVER}=~/https/)
    {
        $useSSL = 1;
    }

    my $port = $useSSL == 1 ? 443 : 80;
    if ($hash->{SERVER}=~/:(\d+)/)
    {
        $hash->{PORT} = $1;
    }

    my $dev = $hash->{SERVER} . ":" . $port . "/" . $hash->{TOPIC} . "/ws";
    if ($hash->{helper}{authString} && length($hash->{helper}{authString})>0)
    {
        $dev .="?auth=" . $hash->{helper}{authString}; 
    }

    # swap http(s) to expected ws(s)
    $dev =~ s/^.*:\/\//wss:/;
    # just for debugging purposes
    NTFY_TOPIC_LOG(LOG_DEBUG,"using websocket url: " . $dev);
    
    $hash->{DeviceName}=$dev;
    $hash->{WEBSOCKET} = 1;
    
    DevIo_OpenDev( $hash, 0, "NTFY_WS_Handshake", "NTFY_WS_CB" );

    return;
}

sub NTFY_TOPIC_Attr
{
  my ( $cmd, $name, $aName, $aValue ) = @_;
  return undef;
}

sub NTFY_WS_Handshake 
{
  my $hash = shift;
  my $name = $hash->{NAME};

  #DevIo_SimpleWrite( $hash, ' ', 2 );
  NTFY_TOPIC_LOG(LOG_DEBUG, "websocket connected");

  readingsSingleUpdate($hash, "state", "connected", 1);

  return;
} 

sub NTFY_WS_CB 
{
    my ($hash, $error)  = @_;

    my $name  = $hash->{NAME};
    
    if ($error)
    {
      readingsBeginUpdate($hash);
      readingsBulkUpdate($hash, "state", "error");
      readingsBulkUpdate($hash, "error", $error);
      readingsEndUpdate($hash,1);

      NTFY_TOPIC_LOG(LOG_ERROR, "error while connecting to websocket: $error ") if $error;
      NTFY_TOPIC_LOG(LOG_DEBUG, "websocket callback called");
    }
    else
    {
      readingsBeginUpdate($hash);
      readingsBulkUpdate($hash, "state", "online");
      readingsBulkUpdate($hash, "error", "none");
      readingsEndUpdate($hash,1);
    }

   
    return $error;

}

sub NTFY_TOPIC_Read
{
	  my ( $hash ) = @_;

    my $buf = DevIo_SimpleRead($hash);

    if (!$buf)
    {
      InternalTimer(gettimeofday()+30, "NTFY_TOPIC_Reconnect", $hash);
      return;
    }

    return unless length($buf) > 0;

    my $msg  = from_json($buf);

    return unless $msg->{event} eq "message";

    my $nrReceivedMessages = ReadingsVal($hash->{NAME},"nrReceivedMessages",0);
    
    $nrReceivedMessages++;
    readingsBeginUpdate($hash);
    readingsBulkUpdateIfChanged($hash,"nrReceivedMessages",$nrReceivedMessages);
    readingsEndUpdate($hash,1);

    Dispatch($hash,"NTFY:" . $hash->{SERVER}. "---" . $buf,{},1);
}


sub NTFY_TOPIC_Reconnect
{
  my $hash = shift;
  if (!DevIo_IsOpen($hash))
  {
    NTFY_TOPIC_LOG(LOG_ERROR, "reconnecting websocket");
    DevIo_OpenDev( $hash, 1, "NTFY_WS_Handshake", "NTFY_WS_CB" );
  }
}

1;