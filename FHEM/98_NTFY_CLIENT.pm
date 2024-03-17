=head1 NAME

NTFY_CLIENT - client for ntfy.sh based servers

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

This module provides push notifications through the ntfy.sh service and
other compatible servers.

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
my $MODULE_NAME="NTFY-CLIENT";
my $VERSION    = '0.0.1';

use constant {
    LOG_CRITICAL        => 0,
    LOG_ERROR           => 1,
    LOG_WARNING         => 2,
    LOG_SEND            => 3,
    LOG_RECEIVE         => 4,
    LOG_DEBUG           => 5,

    PRIO_MAX            => 5,
    PRIO_HIGH           => 4,
    PRIO_DEFAULT        => 3,
    PRIO_LOW            => 2,
    PRIO_MIN            => 1
};

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

  my $auth=encode_base64($username.":".$password, "");
  
  my $authString = encode_base64("Basic " . $auth, "");
  $authString =~ s/=//g;

  return $authString;
}

# initialize the NTFY Module
sub NTFY_CLIENT_Initialize
{
  my ($hash) = @_;
  
  $hash->{Match}      = "^NTFY:.*"; 
  $hash->{DefFn}      = 'NTFY_Define';
  $hash->{SetFn}      = 'NTFY_Set';
  $hash->{ReadFn}     = 'NTFY_Read';
  $hash->{AttrFn}     = 'NTFY_Attr';
  $hash->{ParseFn}    = 'NTFY_Parse';
  $hash->{DeleteFn}   = 'NTFY_Delete';
  $hash->{AttrList}   = "defaultTopic " .
                        "defaultPriority:max,high,default,low,min "
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
    $hash->{VERSION}                = $VERSION;
    $hash->{USERNAME}               = $h->{user} || "";
    $hash->{helper}{PASSWORD}       = $h->{password};
    $modules{NTFY_CLIENT}{defptr}{$hash->{SERVER}} = $hash;

    readingsSingleUpdate($hash, "state", "passive",1);

    return;
}

sub NTFY_Get_Subscriptions
{
  my $hash = shift;
  my @subscriptions;

  for my $k (keys %{$modules{NTFY_TOPIC}{defptr}})
  {
    $k=~/^(.*)_(.*)$/;
    push(@subscriptions,$2);
  }

  return @subscriptions;
}

sub NTFY_Update_Subscriptions_Readings
{
    my $hash = shift;
    my @topics = NTFY_Get_Subscriptions($hash);

    readingsSingleUpdate($hash,"subscriptions", join(",", @topics),1);

}

sub NTFY_newSubscription
{
  my $hash  = shift;
  my $topic = shift;

  my $newDeviceName = makeDeviceName($hash->{NAME} . "_" . $topic);
  
  my $token;
  if ($hash->{helper}->{PASSWORD}) 
  {
    $token= NFTY_Calc_Auth_Token($hash->{helper}->{PASSWORD},$hash->{USERNAME});
    fhem("define $newDeviceName NTFY_TOPIC " . $hash->{SERVER} . " " . $token . " " . $topic);
  }
  else
  {
    fhem("define $newDeviceName NTFY_TOPIC " . $hash->{SERVER} . " " . $topic);
  }

  NTFY_Update_Subscriptions_Readings($hash);
}

sub NTFY_Publish_Msg
{
  my $hash    = shift;
  my $msg     = shift;

  NTFY_LOG(LOG_DEBUG, Dumper($msg));
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
      $message->{priority} = int($msg->{priority});
    }

    if ($msg->{keywords})
    {
      $message->{tags} = $msg->{keywords};
    }


    NTFY_LOG(LOG_DEBUG, "Publish:" . Dumper($message));
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

                       my $nrPublishedMessages = ReadingsVal($hash->{NAME}, "nrPublishedMessages", 0);
                       $nrPublishedMessages++;

                      readingsBeginUpdate($hash);
                      readingsBulkUpdateIfChanged($hash, "nrPublishedMessages", $nrPublishedMessages);
                      readingsBulkUpdateIfChanged($hash, "lastUsedTopic", join(",", @{$msg->{topics}}));
                      readingsBulkUpdateIfChanged($hash, "lastMessageSend", $msg->{text});
                      readingsBulkUpdateIfChanged($hash, "lastRawMessage", to_json($message));
                      if ($msg->{priority} == PRIO_MAX)
                      {
                          readingsBulkUpdateIfChanged($hash, "lastUsedPriority", "max");
                      }
                      elsif ($msg->{priority} == PRIO_HIGH)
                      {
                          readingsBulkUpdateIfChanged($hash, "lastUsedPriority", "high");
                      }
                      elsif ($msg->{priority} == PRIO_DEFAULT)
                      {
                          readingsBulkUpdateIfChanged($hash, "lastUsedPriority", "default");
                      }
                      elsif ($msg->{priority} == PRIO_LOW)
                      {
                          readingsBulkUpdateIfChanged($hash, "lastUsedPriority", "low");
                      }
                      elsif ($msg->{priority} == PRIO_MIN)
                      {
                          readingsBulkUpdateIfChanged($hash, "lastUsedPriority", "min");
                      }
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
  my $priority = AttrVal($name, "defaultPriority", "default");

  my $string=join(" ",@args);
  my $tmpmessage = $string =~ s/\\n/\x0a/rg;
  NTFY_LOG(LOG_DEBUG,"create:" . $tmpmessage);
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
      $priority=lc(substr($a,1,length($a)));
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
  
  if ($priority eq "default")
      {
        $priority=PRIO_DEFAULT;
      }
      elsif($priority eq "max")
      {
        $priority=PRIO_MAX;
      }
      elsif($priority eq "high")
      {
        $priority=PRIO_HIGH;
      }
      elsif($priority eq "low")
      {
        $priority=PRIO_LOW;
      }
      elsif($priority eq "min")
      {
        $priority=PRIO_MIN;
      }
      else 
      {
        $priority=PRIO_DEFAULT;
      }


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
        NTFY_LOG(LOG_DEBUG, "full command: " . join(' ', @args));
        my $msg = NTFY_Create_Msg_From_Arguments($hash, $name,@args);
        NTFY_Publish_Msg($hash, $msg) unless !defined($msg);

        return undef;
    }
    elsif ($cmd eq "subscribe")
    {
        NTFY_LOG(LOG_DEBUG, "full command: " . join(' ', @args));
        NTFY_newSubscription($hash, $args[0]);
    }
    else
    {
        return "Unknown argument $cmd, choose one of publish subscribe"
    }

}

sub NTFY_Attr
{
  my ( $cmd, $name, $aName, $aValue ) = @_;

  
  return undef;
}

#
# Process the incoming notifications/ messages
#
sub NTFY_Process_Message
{
    my $hash = shift;
    my $msg  = shift;

    my $msgData = from_json($msg);

    return unless $msgData->{event} eq "message";

    my $nrReceivedMessages = ReadingsVal($hash->{NAME}, "nrReceivedMessages", 0);
    $nrReceivedMessages++;

    readingsBeginUpdate($hash);
    readingsBulkUpdateIfChanged($hash,"nrReceivedMessages",$nrReceivedMessages);
    readingsBulkUpdateIfChanged($hash,"lastReceivedTopic",$msgData->{topic}) unless !$msgData->{topic};
    readingsBulkUpdateIfChanged($hash,"lastReceivedTitle",$msgData->{title}) unless !$msgData->{title};
    readingsBulkUpdateIfChanged($hash,"lastReceivedData", $msgData->{message}) unless !$msgData->{message};
    readingsBulkUpdateIfChanged($hash,"lastReceivedRawMessage", $msg);
    readingsEndUpdate($hash,1);


}

#
# Parse incoming notifications from websocket clients
#
sub NTFY_Parse ($$)
{
	my ( $ioHash, $message) = @_;

  return unless (substr($message,0,5) eq "NTFY:");

  $message=~/^NTFY:(.*)---(.*)$/;

  my $server = $1;
  my $msg = $2;

  if(my $hash = $modules{NTFY_CLIENT}{defptr}{$server}) 
	{
    NTFY_Update_Subscriptions_Readings($hash);
    NTFY_Process_Message($hash, $msg);
    return $hash->{NAME};
  }

	return;
}

sub NTFY_Delete
{
    my ( $hash, $name ) = @_;

    #we need to delete all topic devices
    for my $k (keys %{$modules{NTFY_TOPIC}{defptr}})
    {
      $k=~/^(.*)_(.*)$/;
      my $h = $modules{NTFY_TOPIC}{defptr}{$k};
      fhem("delete " . $h->{NAME});
    }
}

1;

#########################################

=pod

=item summary A module for pushing and receiving notifications from an ntfy.sh compatible server

=item summary_DE Ein module zu senden und empfangen von Benachrichtigungen über einen ntfy.sh kompatiblen server

=begin html

  <h3>NTFY_CLIENT</h3>
  <a id="NTFY_CLIENT"></a>
  <br/>
  NTFY_CLIENT is a module for connecting to an <a href="https://nfy.sh">ntfy.sh</a> compatible server. <br/> 
  It supports <a href="https://nfy.sh">ntfy.sh</a> in the cloud but also self-hosted instances as long as 
  the fhem server is able to connect to it. <br/>

  <h4>Wiki</h4>
  The wiki for this module can be found <a href="https://rm.byterazor.de/projects/fhem-ntfy/wiki">here</a>.

  <h4>Integration with globalMSG</h4>
  This module integrates with the fhem <a href="#MSG">messaging system</a>. <br/>
  To use it you have to set the <code>msgCmdPush</code> attribute of the 
  <code>globalMSG</code> device to someting like <br/>
  <code>set &#37;DEVICE&#37; publish @&#37;RECIPIENT&#37; !&#37;PRIORITY&#37; *&#37;TITLE&#37; &#37;MSG&#37;</code>
  <br/>
  After that you can use the <code>msg</code> to send out notifications to topics configured within devices.
  <br/>
  Please look for the <a href="#MSG">MSG</a> documentation for more information.


  <a id="NTFY_CLIENT-define"></a>
  <h4>Define</h4>
  <code>define NTFY0 NTFY_CLIENT 	&#60;url&#62; password=&#60;password&#62; user=&#60;user&#62;</code>

  <dl>
    <dt><b>url</b></dt>
    <dd>The url to the ntfy.sh compatible server. This parameter is <b>mandatory</b>.</dd>
    <dt><b>password</b></dt>
    <dd>If you have an account at one ntfy server you can put the password in here. This parameter is optional.</dd>
    <dt><b>user</b></dt>
    <dd>If you have an account at one ntfy server you can put the username in here. This parameter is optional.</dd>
  </dl>

  If you want to use token authentication just set the token as the password and ignore the user parameter.

  <a id="NTFY_CLIENT-set"></a>
  <h4>Set</h4>
  The module supports the following set commands 
  <dl>
    <dt><b>publish</b></dt>
    <dd>
      This set command publishes a notification through the configured ntfy server. <br/>
      <code>set publish @fhem-topic #keyword !high *title this is my message</code><br/>
      The following key tags are supported right now
      <ul>
        <li>@ - identifies a topic. Can be used multiple times.</li>
        <li># - a ntfy keyword. Can be used multiple times.</li>
        <li>! - the priority. The last mentioned priority wins. (max, high, default, low, min) </li>
        <li>* - the title of the notification. The last mentioned title wins. </li>
      </ul>
      Everything without a prefix is considered the messages and is concatenated.
    </dd>
    <dt><b>subscribe</b></dt>
    <dd>
    This set command subscribes to the specified topic on the configured ntfy server.
    For this the client adds a NTFY_TOPIC device which is responsible for the websocket 
    management. Message processing is done in NTFY_CLIENT.
    </dd>
  </dl>
  
  <a id="NTFY_CLIENT-get"></a>
  <h4>Get</h4>
  No get commands supported yet.

  <a id="NTFY_CLIENT-attrib"></a>
  <h4>Attributes</h4>
  <dl>
    <dt><b>defaultTopic</b></dt>
    <dd>
      Sets the default topic used if no topic is provided within the publish string.
    </dd>
    <dt><b>defaultPriority</b></dt>
    <dd>
      Sets the default priority used if no priority is provided within the publish string. 
      Values: (max, high, default, low, min)
    </dd>
  </dl>

=end html

=begin html_DE

 <h3>NTFY_CLIENT</h3>
 <a id="NTFY_CLIENT"></a>
 blabla

=end html_DE

=cut