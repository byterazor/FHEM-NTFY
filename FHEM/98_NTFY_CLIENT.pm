#
# This FHEM Module provides push notifications through the ntfy.sh service and 
# other compatible servers.
#
# Author: Dominik Meyer <dmeyer@đederationhq.de>
#
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
my $MODULE_NAME="NTFY-CLIENT";
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


my %NTFY_SETS =
(
  "_msg" => "textField",
  "message" => "textField",
  "msg" => "textField",
  "send" => "textField"
);


# NTFY logging method
sub NTFY_LOG
{
  my $verbosity = shift;
  my $msg       = shift;

  Log3 $MODULE_NAME, $verbosity, $MODULE_NAME . ":" . $msg;
}

#
# Function to calculate the nfty auth token from a username
# and password/ password token
# 
# the username is allowed to be empty ("")
# the password/password token is mandatory
#
sub NFTY_Calc_Auth_Token
{
  my $password=shift;
  my $username=shift;;

  if (!$username)
  {
    $username="";
  }

  if (!$password)
  {
    NTFY_LOG(LOG_ERROR,"password required for NFTY_Calc_Auth_Token");
    return;
  }

  my $auth=encode_base64($username.":".$password);
  
  my $authString = encode_base64("Basic " . $auth);
  $authString =~ s/=//g;

  return $authString;
}

# initialize the NTFY Module
sub NTFY_CLIENT_Initialize
{
  my ($hash) = @_;
  
  $hash->{DefFn}      = 'NTFY_Define';
  $hash->{SetFn}      = 'NTFY_Set';
  $hash->{ReadFn}     = 'NTFY_Read';
  $hash->{AttrFn}     = 'NTFY_Attr';
  $hash->{AttrList}   = "defaultTopic "
                        . $readingFnAttributes;

}

sub NTFY_Define 
{
    my ($hash, $define) = @_;

    # ensure we have something to parse
    if (!$define)
    {
      warn("$MODULE_NAME: no module definition provided");
      NTFY_LOG(LOG_ERROR,"no module definition provided");
      return;
    }

    # parse parameters into array and hash
    my($params, $h) = parseParams($define);

    my $name                        = makeDeviceName($params->[0]);

    $hash->{NAME}                   = $name;
    $hash->{SERVER}                 = $params->[2];
    $hash->{STATE}                  = "unknown";
    $hash->{USERNAME}               = $h->{user} || "";
    $hash->{helper}{PASSWORD}       = $h->{password};

    my @topics;
    $hash->{helper}->{topics}       = \@topics;

    return;
}

sub NTFY_Update_Subscriptions_Readings
{
    my $hash = shift;

    my $subscriptions="";
    for my $thash (@{$hash->{helper}->{subscriptions}})
    {
      $subscriptions .= $hash->{TOPIC} . ",";
    }
    chop $subscriptions;

    readingsSingleUpdate($hash,"subscriptions", $subscriptions,1);

}

sub NTFY_newSubscription
{
  my $hash  = shift;
  my $topic = shift;

  my $thash = {};
  
  $thash->{NAME}                = makeDeviceName("NTFY_TOPIC_" . $topic);

  $thash->{TYPE}                = $hash->{TYPE};
  $thash->{NR}                  = $devcount++;

  $thash->{phash}               = $hash;
  $thash->{PNAME}               = $hash->{NAME};

  $thash->{TOPIC}               = $topic;
  $thash->{SERVER}              = $hash->{SERVER};
  $thash->{USERNAME}            = $hash->{USERNAME} || "";
  $thash->{helper}->{PASSWORD}  = $hash->{helper}->{PASSWORD};

  $thash->{TEMPORARY} = 1;

  my $useSSL = 0;
  if ($thash->{SERVER}=~/https/)
  {
    $useSSL = 1;
  }

  my $port = $useSSL == 1 ? 443 : 80;
  if ($thash->{SERVER}=~/:(\d+)/)
  {
    $port = $1;
  }

  my $dev = $thash->{SERVER} . ":" . $port . "/" . $thash->{TOPIC} . "/ws";

  if ($thash->{helper}->{PASSWORD} && length($thash->{helper}->{PASSWORD}) > 0)
  {
    my $token = NFTY_Calc_Auth_Token($thash->{helper}->{PASSWORD},$thash->{USERNAME});
    if (!$token)
    {
      NTFY_LOG(LOG_ERROR,"Can not suscribe to topic without valid token");
      return;
    }

    $dev .="?auth=" . $token; 
  } 

  # swap http(s) to expected ws(s)
  $dev =~ s/^.*:\/\//wss:/;

  # just for debugging purposes
  NTFY_LOG(LOG_ERROR,"using websocket url: " . $dev);

  $thash->{DeviceName}=$dev;
  $thash->{WEBSOCKET} = 1;
  
  $attr{$thash->{NAME}}{room} = 'hidden';
  $defs{$thash->{NAME}}       = $thash;
  
  DevIo_OpenDev( $thash, 0, "NTFY_WS_Handshake", "NTFY_WS_CB" );

  # remember topic in main hash helper 
  push(@{$hash->{helper}->{topics}},$thash);

  NTFY_Update_Subscriptions_Readings($hash);
}

sub NTFY_Topic_To_Hash
{
  my $hash  = shift;
  my $topic = shift;


}

sub NTFY_WS_Handshake 
{
  my $hash = shift;
  my $name = $hash->{NAME};

  DevIo_SimpleWrite( $hash, '', 2 );
  NTFY_LOG(LOG_ERROR, "websocket connected");

  readingsSingleUpdate($hash, "state", "online", 1);
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
    }

    NTFY_LOG(LOG_ERROR, "error while connecting to websocket: $error ") if $error;
    NTFY_LOG(LOG_DEBUG, "websocket callback called");
    return $error;

}

sub NTFY_Read
{
	my ( $hash ) = @_;

  my $buf = DevIo_SimpleRead($hash);

  return unless length($buf) > 0;

  my $msg  = from_json($buf);

  return unless $msg->{event} eq "message";

  my $nrReceivedMessages = ReadingsVal($hash->{phash},"nrReceivedMessages",0);
  +
  $nrReceivedMessages++;
  readingsBeginUpdate($hash->{phash});
  readingsBulkUpdateIfChanged($hash->{phash},"nrReceivedMessages",$nrReceivedMessages++);
  readingsBulkUpdateIfChanged($hash->{phash}, "lastReceivedTopic", $msg->{topic});
  readingsEndUpdate($hash->{phash},1);

  NTFY_LOG(LOG_ERROR, $hash->{NAME} . " received: " . $buf);

}
sub NTFY_Publish_Msg
{
  my $hash    = shift;
  my $msg     = shift;

  NTFY_LOG(LOG_ERROR, Dumper($msg));
  my $auth    = "";
  if ($hash->{helper}->{PASSWORD} && length($hash->{helper}->{PASSWORD}) > 0)
  {
    my $token = NFTY_Calc_Auth_Token($hash->{helper}->{PASSWORD},$hash->{USERNAME});
    if (!$token)
    {
      NTFY_LOG(LOG_ERROR,"Can not publish to topic without valid token");
      return;
    }

    $auth .="?auth=" . $token; 
  } 

  
  for my $topic (@{$msg->{topics}})
  {
    my $url     = $hash->{SERVER} ."/". $auth;
    
    my $message = {
      topic     => $topic,
      message   => $msg->{text},
    };

    if ($msg->{title})
    {
      $message->{title} = $msg->{title};
    }

    if ($msg->{priority})
    {
      $message->{priority} = $msg->{priority};
    }

    NTFY_LOG(LOG_ERROR, "Publish:" . Dumper($message));
    my $param = {
                    url        => $url,
                    timeout    => 5,
                    hash       => $hash,                                                                                 
                    method     => "POST",
                    data       => to_json($message),                                                                                 
                    callback   => sub () {
                      my ($param, $err, $data) = @_;
                      my $hash = $param->{hash};
                      my $name = $hash->{NAME};

                      if($err ne "")
                      {
                        NTFY_LOG(LOG_ERROR, "Error publishing to topic ");
                        readingsSingleUpdate($hash, "lastError", $err,1);
                        return;
                      }

                      readingsBeginUpdate($hash);
                      readingsBulkUpdateIfChanged($hash, "lastUsedTopic", $msg->{topic});
                      readingsBulkUpdateIfChanged($hash, "lastMessageSend", $msg->{text});
                      readingsBulkUpdateIfChanged($hash, "lastRawMessage", to_json($message));
                      readingsBulkUpdateIfChanged($hash, "lastEror", "");
                      readingsEndUpdate($hash,1);

                    }                                                                  
                };
         HttpUtils_NonblockingGet($param);
  }
}

sub NTFY_Create_Msg_From_Arguments
{
  my $hash = shift;
  my $name = shift;
  my @args = @_;

  my @topics;
  my @attachments;
  my @keywords;
  my $text;
  my $title;
  my $priority = AttrVal($name, "defaultPriority", PRIO_DEFAULT);

  my $string=join(" ",@args);
  my $tmpmessage = $string =~ s/\\n/\x0a/rg;
  NTFY_LOG(LOG_ERROR,"create:" . $tmpmessage);
  @args=parse_line(' ',0,$tmpmessage);

  for my $a (@args)
  {
    if (substr($a,0,1) eq "@")
    {
      push(@topics, substr($a,1,length($a)));
    }
    elsif (substr($a,0,1) eq "#")
    {
      push(@keywords, substr($a,1,length($a)));
    }
    elsif (substr($a,0,1) eq "&")
    {
      push(@attachments, substr($a,1,length($a)));
    }
    elsif (substr($a,0,1) eq "!")
    {
      my $tmpPriority=substr($a,1,length($a));
      if ($tmpPriority eq "default")
      {
        $priority=PRIO_DEFAULT;
      }
      elsif($tmpPriority eq "high")
      {
        $priority=PRIO_HIGH;
      }
      elsif($tmpPriority eq "low")
      {
        $priority=PRIO_LOW;
      }
    }
    elsif (substr($a,0,1) eq "*")
    {
      $title=substr($a,1,length($a));
    }
    else 
    {
      $text .= $a . " ";
    }
  }
  chop $text;
  
  if (@topics == 0)
  {
    my $defaultTopic = AttrVal($name, "defaultTopic",undef);
    if (!defined($defaultTopic))
    {
      NTFY_LOG(LOG_WARNING, "no topic and no default topic given, can not publish");
      return;
    }
    else
    {
      push(@topics, $defaultTopic);
    }
  }

  my $msg = 
  {
      topics => \@topics,
      title => $title,
      keywords => \@keywords,
      attachments => \@attachments,
      priority => $priority,
      text => $text
  };
  
  return $msg;
}

sub NTFY_Set 
{
    my ( $hash, $name, $cmd, @args ) = @_;
    
    if ($cmd eq "publish" )
    {
        NTFY_LOG(LOG_ERROR, "full command: " . join(' ', @args));
        my $msg = NTFY_Create_Msg_From_Arguments($hash, $name,@args);
        NTFY_Publish_Msg($hash, $msg) unless !defined($msg);

        return undef;
    }
    else
    {
        return "Unknown argument $cmd, choose one of publish"
    }

}

sub NTFY_Attr
{
  my ( $cmd, $name, $aName, $aValue ) = @_;
  return undef;
}


1;