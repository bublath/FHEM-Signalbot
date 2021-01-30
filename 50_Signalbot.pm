##############################################
# $Id$
# Simple Interface to Signal CLI running as Dbus service
#
package main;

use strict;
use warnings;
use Net::DBus;
use Net::DBus::Reactor;
use Scalar::Util qw(looks_like_number);
use File::Temp qw( tempfile tempdir );
use Text::ParseWords;


eval "use Net::DBus;1" or my $NETDBus = "Net::DBus";
eval "use Net::DBus::Reactor;1" or my $NETDBusReactor = "Net::DBus::Reactor";

my %sets = (
  "send" => "textField",
  "refreshGroups" => "noArg",
  "reinit" => "noArg",
  "saveContacts" => "noArg"
 );

my $sep="##"; #Seperator used for splitting message content passed from Child to Parent
my $Signalbot_devicename="";

sub Signalbot_Initialize($) {
  my ($hash) = @_;

  $hash->{DefFn}     = 	"Signalbot_Define";
  $hash->{InitFn}  	 =  'Signalbot_Init';
  $hash->{AttrFn}    = 	"Signalbot_Attr";
  $hash->{SetFn}     = 	"Signalbot_Set";
  $hash->{NotifyFn}  =  'Signalbot_Notify';
  $hash->{ReadFn}    = 	"Signalbot_Read";
  $hash->{StateFn}   =  "Signalbot_State";
  $hash->{GetFn}     = 	"Signalbot_Get";
  $hash->{UndefFn}   = 	"Signalbot_Undef";
  $hash->{AttrList}  = 	"IODev do_not_notify:1,0 ignore:1,0 showtime:1,0 ".
												"defaultPeer: ".
												"poll_interval: ".
												"$readingFnAttributes";
}
################################### Todo: Set or Attribute for Mode? Other sets needed?
sub Signalbot_Set($@) {					#

  my ( $hash, $name, @args ) = @_;
  
#  Log3 $hash->{NAME}, 5, "Signalbot_Set $name: called "; 

  ### Check Args
  my $numberOfArgs  = int(@args);
  return "Signalbot_Set: No cmd specified for set" if ( $numberOfArgs < 1 );

  my $cmd = shift @args;

  if (!exists($sets{$cmd}))  {
    my @cList;
    foreach my $k (keys %sets) {
      my $opts = undef;
      $opts = $sets{$k};

      if (defined($opts)) {
        push(@cList,$k . ':' . $opts);
      } else {
        push (@cList,$k);
      }
    } # end foreach
    return "Signalbot_Set: Unknown argument $cmd, choose one of " . join(" ", @cList);
  } # error unknown cmd handling

	if ( $cmd eq "refreshGroups") {
		#Gruppen neu einlesen
		Signalbot_Refreshgroups($hash);
		return undef;
	} elsif ( $cmd eq "send") {
		return "Usage: set ".$hash->{NAME}." send [@<Recipient1> ... @<RecipientN>] [#<GroupId1> ... #<GroupIdN>] [&<Attachment1> ... &<AttachmentN>] [<Text>]" if ( int(@args)==0); 

		my @recipients = ();
		my @groups = ();
		my @attachments = ();
		my $message = "";
		#To allow spaces in strings, join string and split it with parse_line that will honor spaces embedded by double quotes
		my $fullstring=join(" ",@args);
		my @args=parse_line(' ',0,$fullstring);

		while(my $curr_arg = shift @args){
			if($curr_arg =~ /^\@(.*)$/){
				push(@recipients,$1);
			}elsif($curr_arg =~ /^#(.*)$/){
				push(@groups,$1);
			}elsif($curr_arg =~ /^\&(.*)$/){
				push(@attachments,$1);
			}else{
				unshift(@args,$curr_arg);
				last;
			}

		}
		my $defaultPeer=AttrVal($hash->{NAME},"defaultPeer",undef);
		return "Not enough arguments. Specify a Recipient, a GroupId or set the defaultPeer attribute" if( (int(@recipients) == 0) && (int(@groups) == 0) && (!defined $defaultPeer) );

		#Check for embedded fhem/perl commands
		my $err;
		($err, @recipients) = SignalBot_replaceCommands($hash,@recipients);
		if ($err) { return $err; }
		($err, @groups) = SignalBot_replaceCommands($hash,@groups);
		if ($err) { return $err; }
		($err, @attachments) = SignalBot_replaceCommands($hash,@attachments);
		if ($err) { return $err; }
		
		#Am Schluss eine Schleife über die Attachments und alle die mit /tmp/signalbot anfangen löschen (unlink)

		if ((defined $defaultPeer) && int(@recipients) == 0 && int(@groups) == 0) {

			my @peers = split(/,/,$defaultPeer);
			while(my $curr_arg = shift @peers){
				if($curr_arg =~ /^#/){
					push(@groups,$curr_arg);
				} else {
					push(@recipients,$curr_arg);
				}
			}
		}
		return "Specify either a message text or an attachment" if((int(@attachments) == 0) && (int(@args) == 0));

		$message = join(" ", @args);
	
		#Send message to individuals (bulk)
		if (@recipients > 0) {
			my $ret=Signalbot_sendMessage($hash,join(",",@recipients),join(",",@attachments),$message);
			return $ret if defined $ret;
		}
		if (@groups > 0) {
		#Send message to groups (one at time)
			while(my $currgroup = shift @groups){
				my $ret=Signalbot_sendGroupMessage($hash,$currgroup,join(",",@attachments),$message);
				return $ret if defined $ret;
			}
		}
		#Remove the tempfiles
		foreach my $file (@attachments) {
			if ($file =~ /tmp\/signalbot/) {
				unlink $file;
			}
		}
	} elsif ( $cmd eq "reinit") {
		Signalbot_setup($hash);
	} elsif ( $cmd eq "saveContacts") {
		Log3 $hash->{NAME}, 5, "saveContacts to reading";  
		my $contacts=$hash->{helper}{contacts};
		my $clist="";
		my $first=1;
		if (defined $contacts) {
			foreach my $key (keys %{$contacts}) {
				my $val=$contacts->{$key};
				if ($first) { $first=0; } else { $clist.=","; }
				$clist.="$key=$val";
			}
			readingsSingleUpdate($hash, 'contactList', $clist,0);
		}
	}
  	return undef;
}
################################### 
sub Signalbot_Get($@) {
	#Nothing to be done here, let all updates run asychroniously with timers
	return undef;
}

sub Signalbot_message_callback {
	my ($hash, $timestamp, $source, $groupID, $message, $attachments) = @_;

	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Message Callback";
	
	#Copy previous redings to keep history of on message
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "prevMsgTimestamp", ReadingsVal($hash->{NAME}, "msgTimestamp", undef)) if defined ReadingsVal($hash->{NAME}, "msgTimestamp", undef);
	readingsBulkUpdate($hash, "prevMsgText", ReadingsVal($hash->{NAME}, "msgText", undef)) if defined ReadingsVal($hash->{NAME}, "msgText", undef);
	readingsBulkUpdate($hash, "prevMsgSender", ReadingsVal($hash->{NAME}, "msgSender", undef)) if defined ReadingsVal($hash->{NAME}, "msgSender", undef);
	readingsBulkUpdate($hash, "prevMsgGroupName", ReadingsVal($hash->{NAME}, "msgGroupName", undef)) if defined ReadingsVal($hash->{NAME}, "msgGroupName", undef);
	readingsBulkUpdate($hash, "prevMsgGroupId", ReadingsVal($hash->{NAME}, "msgGroupId", undef)) if defined ReadingsVal($hash->{NAME}, "msgGroupId", undef);
	readingsBulkUpdate($hash, "prevMsgAttachment", ReadingsVal($hash->{NAME}, "msgAttachment", undef)) if defined ReadingsVal($hash->{NAME}, "msgAttachment", undef);
	readingsEndUpdate($hash, 0);

	my @groups=@$groupID;
	my $tmp="";
	foreach (@groups) {
		$tmp.=$_." " if defined $_;
	} 	
	my $group=Signalbot_translateGroup($hash,trim($tmp));
	
	$tmp="";
	my @att=@$attachments;
	foreach (@att) {
		$tmp.= $_." " if defined $_;
	}	
	
	my $sender=Signalbot_getContactName($hash,$source);
	
	if (!defined $sender) {
		Log3 $hash->{NAME}, 5, $hash->{NAME}.":Issue with resolving contact $source\n";
		$sender=$source;
	}

	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "msgAttachment", trim($tmp));
	readingsBulkUpdate($hash, "msgTimestamp", strftime("%d-%m-%Y %H:%M:%S", localtime($timestamp/1000)));
	readingsBulkUpdate($hash, "msgText", $message);
	readingsBulkUpdate($hash, "msgSender", $sender);
	readingsBulkUpdate($hash, "msgGroupName", $group);
	readingsEndUpdate($hash, 1);

	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Message from $sender : $message processed";
}

sub Signalbot_receipt_callback {
	my ($hash, $timestamp, $source) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Signalbot_receive_callback $timestamp $source ";
	my $sender=Signalbot_getContactName($hash,$source);
	
	if (!defined $sender) {
		Log3 $hash->{NAME}, 5, $hash->{NAME}.":Issue with resolving contact $source\n";
		$sender=$source;
	}
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "sentMsgRecipient", $sender);
	readingsBulkUpdate($hash, 'sentMsgTimestamp', strftime("%d-%m-%Y %H:%M:%S", localtime($timestamp/1000)));
	readingsEndUpdate($hash, 0);
}

sub Signalbot_sync_callback {
	my ($hash,$timestamp, $source, $string1, $array1, $string2, $array2) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}."Signalbot: Signalbot_sync_callback $timestamp $source";
	my $tmp="";
	my @arr1=@$array1;
	foreach (@arr1) {
		$tmp.=$_." " if defined $_;
	} 

	my @arr2=@$array2;
	foreach (@arr2) {
		$tmp.= $_." " if defined $_;
	} 	
}

sub Signalbot_disconnect($@) {
    my ($hash) = @_;
	my $name=$hash->{NAME};
	eval { 
		if ($hash->{helper}{dbus} ) {
			#Cleanup helper structures to allow reinit
			my $reactor=$hash->{helper}{dreactor};
			if (defined $reactor) {
				my $timer=$hash->{helper}{timer};
				if (defined $timer) {
					$reactor->remove_timeout($timer);
					delete $hash->{helper}{timer};
				}
				delete $hash->{helper}{dreactor};
			}
			my $object=$hash->{helper}{dobject};
			if (defined $object) {
				my $msignal=$hash->{helper}{msignal};
				if (defined $msignal) {
					$object->disconnect_from_signal($msignal);
					delete $hash->{helper}{msignal};
				}
				my $ssignal=$hash->{helper}{ssignal};
				if (defined $ssignal) {
					$object->disconnect_from_signal($ssignal);
					delete $hash->{helper}{ssignal};
				}
				my $rsignal=$hash->{helper}{rsignal};
				if (defined $rsignal) {
					$object->disconnect_from_signal($rsignal);
					delete $hash->{helper}{rsignal};
				}
				delete $hash->{helper}{dobject};
			}
			delete $hash->{helper}{service} if defined $hash->{helper}{dservice};
			delete $hash->{helper}{dbus} if defined $hash->{helper}{dbus};
		}
	}; 
	if ($@) {
		Log3 $name, 5, "Error in disconnect:".$@;
	}
	Log3 $name, 5, "Disconnected and cleaned up";
}

sub Signalbot_setup($@){
    my ($hash) = @_;
	my $name=$hash->{NAME};
	if (defined $hash->{helper}{dbus}) {
		#Reinitialize everything to avoid double callbacks and other issues
		Signalbot_disconnect($hash);
	}	
	delete $hash->{helper}{contacts};
	my $bus = Net::DBus->system;
	return "Error getting Dbus" unless defined $bus;
	$hash->{helper}{dbus}=$bus;
	my $service = $bus->get_service("org.asamk.Signal");
	return "Error getting Dbus service" unless defined $service;
	$hash->{helper}{dservice}=$service;
	my $object = $service->get_object("/org/asamk/Signal");
	return "Error getting Dbus object" unless defined $object;
	$hash->{helper}{dobject}=$object;	
	my $reactor=Net::DBus::Reactor->main();	
	return "Error getting Dbus reactor" unless defined $reactor;
	$hash->{helper}{dreactor}=$reactor;
	#Always check if callbacks are already defined to avoid getting multiple callbacks

	$hash->{helper}{msignal} = $object->connect_to_signal("MessageReceived", 
		sub { Signalbot_message_callback($hash,@_);} ) 
		unless defined $hash->{helper}{msignal} ;
	Log3 $name, 5, "Added message signal ".$hash->{helper}{msignal};
	$hash->{helper}{ssignal} = $object->connect_to_signal("SyncMessageReceived", 
		sub { Signalbot_sync_callback($hash,@_);} ) 
		unless defined $hash->{helper}{ssignal} ;
	Log3 $name, 5, "Added sync signal ".$hash->{helper}{ssignal};
	$hash->{helper}{rsignal} = $object->connect_to_signal("ReceiptReceived", 
		sub { Signalbot_receipt_callback($hash,@_);} ) 
		unless defined $hash->{helper}{rsignal} ;
	Log3 $name, 5, "Added receipt signal ".$hash->{helper}{rsignal};

	#Set a very short timer that guarantees that the $reactor->step() function still immediately returns when there is nothing to do.
	$hash->{helper}{timer} = $reactor->add_timeout(1,
       Net::DBus::Callback->new(method => sub {
	      #Do nothing
		})) unless defined $hash->{helper}{timer}; 	
	my $count = 0;
	my $fds=undef;
    foreach (keys %{$reactor->{fds}->{read}}) {
	next unless $reactor->{fds}->{read}->{$_}->{enabled};
	$fds=$_;
	$count++;
    }
	return "Error getting Dbus filehandler" unless defined $fds;
	if ($count!=1) {
	Log3 $name, 5, "$name: Unexpected number of filehandles";
	}
	Log3 $name, 5, "$name: Initializing Dbus with filehandle $fds";
	$hash->{FD}=$fds;
    $selectlist{"$name.dbus"} = $hash;
	
	#Restore contactlist into internal hash
	my $clist=ReadingsVal($hash->{NAME}, "contactList",undef);
	if (defined $clist) {
		my @contacts=split(",",$clist);
		foreach my $val (@contacts) {
			my ($k,$v) = split ("=",$val);
			$hash->{helper}{contacts}{$k}=$v;
		}
	}
}

sub Signalbot_Read($@){
    my ($hash) = @_;
	my $reactor=$hash->{helper}{dreactor};
	return "Error Dbus rector not set" unless defined $reactor;
	#Set a timer to avoid that 

	$reactor->{running} = 1; #Otherwise step won't read anything and we have a endless loop calling this again
    $reactor->step(); #Step twice just in case there is more queued up. There is no way I know of to check if the queue is empty already
    $reactor->step();
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Read from Dbus done";
}

sub Signalbot_getContactName($@) {
    my ( $hash,$number) = @_;

	#check internal inventory
	my $contact=$hash->{helper}{contacts}{$number};

	#if not found, ask Signal
	if (!defined $contact) {
		my $object=$hash->{helper}{dobject};
		return "Dbus not initialized" unless defined $object;
		eval {
			$contact = $object->getContactName($number);	
		}; return $@ unless defined $@;
		#Add to internal inventory
		$hash->{helper}{contacts}{$number}=$contact;
	}
	return $contact;
}

sub Signalbot_translateContact($@) {
    my ($hash,$contact) = @_;
	#if contact looks like a number +..... just return it so this can even be called transparently for numbers and contact names
	return $contact if ( $contact =~ /^\+/ );
	my $con=$hash->{helper}{contacts};

	foreach my $key (keys %{$con}) {
		my $val=$con->{$key};
		return $key if $val eq $contact;		
    }
	return undef;
}

sub Signalbot_translateGroup($@) {
    my ($hash, $groupID) = @_;
	my $groups=$hash->{helper}{groups};
	
	#Don't try to translate empty groupname
	if ($groupID eq "") { return ""; }
	
	foreach my $key (keys %{$groups}) {
		my $val=$groups->{$key};
		return $key if $val eq $groupID;		
    }
	#Group not found, so check if we simply don't know it yet
	Signalbot_Refreshgroups($hash);
	#And try again
	$groups=$hash->{helper}{groups};
	foreach my $key (keys %{$groups}) {
		my $val=$groups->{$key};
		return $key if $val eq $groupID;		
    }
	return "Unknown group";
}

sub Signalbot_getNumber($@) {
    my ( $hash,$rec) = @_;
	my @recipient= split(/,/,$rec);
	
	#Das klappt nicht - kann man die Contacts nicht abfragen????
	#Interne liste in den readings pflegen, die bei setContactName geupdated wird und gespeichert bleibt?
	
	foreach(@recipient) {
		my $number=$hash->{helper}{contacts}{$_};
		if (!defined($number)){
		    my $bus = Net::DBus->system;
			my $service = $bus->get_service("org.asamk.Signal");
			my $object = $service->get_object("/org/asamk/Signal");

			my $number = 1;
		}
	}
}

sub Signalbot_Refreshgroups($@) {
    my ( $hash ) = @_;

	my $object=$hash->{helper}{dobject};
	return "Dbus not initialized" unless defined $object;

	my $grouplist="";
	my $ret = $object->getGroupIds();
	my @groups = @$ret;
	foreach (@groups) {
		my @group=@$_;
		my $groupname = $object->getGroupName(\@group);
		$hash->{helper}{groups}{$groupname}=join(" ",@group);	
		Log3 $hash->{NAME}, 5, "found group ".$groupname; 
		$grouplist=$grouplist." ".$groupname;
	}
	readingsSingleUpdate($hash, 'joinedGroups', $grouplist,0);	
}

sub Signalbot_sendMessage($@) {
    my ( $hash,$rec,$att,$mes ) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": sendMessage called for $rec:$att:$mes"; 

	my @recorg= split(/,/,$rec);
	my @attach=split(/,/,$att);
	my @recipient=();
	foreach (@recorg) {
		my $trans=Signalbot_translateContact($hash,$_);
		return "Unknown recipient ".$_ unless defined $trans;
		push @recipient, $trans;
	}
	my $object=$hash->{helper}{dobject};
	return "Dbus not initialized" unless defined $object;

    eval { $object->sendMessage($mes,\@attach,\@recipient); };
	return "Error sending message:".$@ if $@;
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "sentMsg", $mes);
	readingsBulkUpdate($hash, 'sentMsgTimestamp', "pending");
	readingsEndUpdate($hash, 0);
}

sub Signalbot_sendGroupMessage($@) {
    my ( $hash,$rec,$att,$mes ) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": sendGroupMessage called for $rec:$att:$mes"; 

	$rec=~s/#//g;
	my @recipient= split(/,/,$rec);
	if (scalar(@recipient)>1) { return "Can only send to one group at once";}
	my @attach=split(/,/,$att);
	my @arr="";
	my $group=$hash->{helper}{groups}{$rec};
	if (defined($group)) {
		@arr=split(" ",$group);
	} else {
		#Check if we need to cache a new group
		Signalbot_Refreshgroups($@);
		$group=$hash->{helper}{groups}{$rec};
		return "Unknown group ".$_." please check or refresh group list" unless defined $group;
	}

	my $object=$hash->{helper}{dobject};
	return "Dbus not initialized" unless defined $object;	

	eval { $object->sendGroupMessage($mes,\@attach,\@arr); };
	return "Error sending message:".$@ if $@;
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "sentMsg", $mes);
	readingsBulkUpdate($hash, 'sentMsgTimestamp', "pending");
	readingsEndUpdate($hash, 0);
}

sub Signalbot_Execute($@) {
	my ($hash) = @_;
	#Additional check for pending message with polling if defined
	my $reactor=$hash->{helper}{reactor};
	my $ret=$reactor->step() if defined $reactor;
	my $pollInterval = AttrVal($hash->{NAME}, 'poll_interval', 0)*60;
	InternalTimer(gettimeofday() + 1, 'Signalbot_Execute', $hash, 0) if ($pollInterval > 0);
}

################################### 
sub Signalbot_Attr(@) {					#
 my ($command, $name, $attr, $val) = @_;
 my $hash = $defs{$name};
 my $msg = undef;

  if ($attr eq 'poll_interval') {
    if ( defined($val) ) {
      if ( looks_like_number($val) && $val >= 0) {
        RemoveInternalTimer($hash);
        InternalTimer(gettimeofday()+1, 'Signalbot_Execute', $hash, 0) if $val>0;
      } else {
        $msg = "$hash->{NAME}: Wrong poll intervall defined. poll_interval must be a number >= 0";
      }    
    } else {
      RemoveInternalTimer($hash);
    }
  }

  #check for correct values while setting so we need no error handling later
  foreach ('xx', 'yy') {
	if ($attr eq $_) {
		if ( defined($val) ) {
			if ( !looks_like_number($val) || $val <= 0) {
				$msg = "$hash->{NAME}: ".$attr." must be a number > 0";
			}
		}
	}
  }
  return $msg;	
}

sub Signalbot_Notify($$) {
  my ($own_hash, $dev_hash) = @_;
  my $ownName = $own_hash->{NAME}; # own name / hash

  return "" if(IsDisabled($ownName)); # Return without any further action if the module is disabled

  my $devName = $dev_hash->{NAME}; # Device that created the events
  my $events = deviceEvents($dev_hash,1);
  
  if ($devName eq "global" and grep(m/^INITIALIZED|REREADCFG$/, @{$events})) {
	  Signalbot_Init($own_hash,());
  }
}

################################### 
sub Signalbot_Define($$) {			#
	my ($hash, $def) = @_;

	return "Error while loading $NETDBus. Please install $NETDBus" if $NETDBus;
	return "Error while loading $NETDBusReactor. Please install $NETDBusReactor" if $NETDBusReactor;

	$Net::DBus::VERSION =~ /^([0-9]+)\.([0-9]+)\.([0-9]+)$/;
	if(($1*100+$2*10+$3) < 120){
		return "Please install Net::DBus in version 1.2.0 or higher. Your version is: $Net::DBus::VERSION"
	}
	
	$hash->{NOTIFYDEV} = "global";
 
	my @a = split("[ \t]+", $def);
		if ($init_done) {
			eval { Signalbot_Init( $hash, [ @a[ 2 .. scalar(@a) - 1 ] ] ); };
		return Signalbot_Catch($@) if $@;
	}
	return undef;
}
################################### 
sub Signalbot_Init($$) {				#
	my ( $hash, $args ) = @_;
	#my @a = split("[ \t]+", $args);
	my $name = $hash->{NAME};
	if (defined $args && int(@$args) != 0)	{
		return "Define: Wrong syntax. Usage:\n" .
		       "define <name> Signalbot";
	}

	Signalbot_Set($hash, $name, "setfromreading");
	Signalbot_setup($hash);
	RemoveInternalTimer($hash);
	my $pollInterval = AttrVal($hash->{NAME}, 'poll_interval', 0)*60;
	InternalTimer(gettimeofday() + 1, 'Signalbot_Execute', $hash, 0) if ($pollInterval > 0);
	return;
}

################################### 
sub Signalbot_Catch($) {
	my $exception = shift;
	if ($exception) {
		$exception =~ /^(.*)( at.*FHEM.*)$/;
		return $1;
	}
	return undef;
}
################################### 
sub Signalbot_State($$$$) {			#reload readings at FHEM start
	my ($hash, $tim, $sname, $sval) = @_;

	return undef;
}
################################### 
sub Signalbot_Undef($$) {				#
	my ($hash, $name) = @_;
	Signalbot_disconnect($hash);
	RemoveInternalTimer($hash) if ( defined (AttrVal($hash->{NAME}, "poll_interval", undef)) ); 
	return undef;
}

#Any part of the message can contain FHEM or {perl} commands that get executed here
#This is marked by being in (brackets) - returned is the result (without brackets)
#If its a media stream, a file is being created and the temporary filename (delete later!) is returned
#Question: more complex commands could contain spaces but that will require more complex parsing

sub SignalBot_replaceCommands(@) {
	my ($hash, @data) = @_;
	
	my @processed=();
	
	foreach my $string (@data) {
		#Commands need to be enclosed in brackets
		if ($string =~ /^\((.*)\)$/) {
			$string=$1; #without brackets
			my %dummy; 
			my ($err, @newargs) = ReplaceSetMagic(\%dummy, 0, ( $string ) );
			my $msg="";
			if ( $err ) {
				Log3 $hash->{NAME}, 1, $hash->{NAME}.": parse cmd failed on ReplaceSetmagic with :$err: on  :$string:";
			} else {
				$msg = join(" ", @newargs);
				Log3 $hash->{NAME}, 4, $hash->{NAME}.": parse cmd returned :$msg:";
			}
			$msg = AnalyzeCommandChain( $hash, $msg );
			#If a normal FHEM command (no return value) is executed, $msg is undef - just the to empty string then
			if (!defined $msg) { 
				$msg=""; 
				Log3 $hash->{NAME}, 4, $hash->{NAME}.": commands executed without return value";
			}
			#Only way to distinguish a real error with the return stream
			if ($msg =~ /^Unknown command/) { 
				Log3 $hash->{NAME}, 4, $hash->{NAME}.": Error message: ".$msg;
				return ($msg, @processed); 
			}
			
			my ( $isMediaStream, $type ) = SignalBot_IdentifyStream( $hash, $msg ) if ( defined( $msg ) );
			if ($isMediaStream<0) {
				Log3 $hash->{NAME}, 4, $hash->{NAME}.": Media stream found $isMediaStream $type";
				my $tmpfilename="/tmp/signalbot".gettimeofday().".".$type;
				my $fh;
				#tempfile() would be the better way, but is not readable by signal-cli (how to set world-readable?)
				#my ($fh, $tmpfilename) = tempfile();
				if(!open($fh, ">", $tmpfilename,)) {
				#if (!defined $fh) {
					Log3 $hash->{NAME}, 1, $hash->{NAME}.": Can't write $tmpfilename";
					#return undef since this is a fatal error 
					return ("Can't write $tmpfilename",@processed);
				}
				print $fh $msg;
				close($fh);
				#If we created a file return the filename instead
				push @processed, $tmpfilename;
			} else {
				Log3 $hash->{NAME}, 4, $hash->{NAME}.": normal text found:$msg";
				#No mediastream - return what it was
				push @processed, $msg;
			}
		} else {
			#Not even in brackets, return as is
			push @processed, $string;
		}
		
	}
	
	return (undef,@processed);
}


######################################
#  Get a string and identify possible media streams
#  Copied from Telegrambot
#  PNG is tested
#  returns 
#   -1 for image
#   -2 for Audio
#   -3 for other media
# and extension without dot as 2nd list element

sub SignalBot_IdentifyStream($$) {
  my ($hash, $msg) = @_;

  # signatures for media files are documented here --> https://en.wikipedia.org/wiki/List_of_file_signatures
  # seems sometimes more correct: https://wangrui.wordpress.com/2007/06/19/file-signatures-table/
  return (-1,"png") if ( $msg =~ /^\x89PNG\r\n\x1a\n/ );    # PNG
  return (-1,"jpg") if ( $msg =~ /^\xFF\xD8\xFF/ );    # JPG not necessarily complete, but should be fine here
  
  return (-2 ,"mp3") if ( $msg =~ /^\xFF\xF3/ );    # MP3    MPEG-1 Layer 3 file without an ID3 tag or with an ID3v1 tag
  return (-2 ,"mp3") if ( $msg =~ /^\xFF\xFB/ );    # MP3    MPEG-1 Layer 3 file without an ID3 tag or with an ID3v1 tag
  
  # MP3    MPEG-1 Layer 3 file with an ID3v2 tag 
  #   starts with ID3 then version (most popular 03, new 04 seldom used, old 01 and 02) ==> Only 2,3 and 4 are tested currently
  return (-2 ,"mp3") if ( $msg =~ /^ID3\x03/ );    
  return (-2 ,"mp3") if ( $msg =~ /^ID3\x04/ );    
  return (-2 ,"mp3") if ( $msg =~ /^ID3\x02/ );    

  return (-3,"pdf") if ( $msg =~ /^%PDF/ );    # PDF document
  return (-3,"docx") if ( $msg =~ /^PK\x03\x04/ );    # Office new
  return (-3,"docx") if ( $msg =~ /^PK\x05\x06/ );    # Office new
  return (-3,"docx") if ( $msg =~ /^PK\x07\x08/ );    # Office new
  return (-3,"doc") if ( $msg =~ /^\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1/ );    # Office old - D0 CF 11 E0 A1 B1 1A E1

  return (-4,"mp4") if ( $msg =~ /^....\x66\x74\x79\x70\x69\x73\x6F\x6D/ );    # MP4 according to Wikipedia
  return (-4,"mpg") if ( $msg =~ /^\x00\x00\x01[\xB3\xBA]/ );    # MPG according to Wikipedia
  
  return (0,"txt");
}

1;

#Todo Write update documentation

=pod
=item device
=item summary provides an interface to the Signal Messenger, via signal_cli running as dbus daemon 
=item summary_DE stellt eine Schnittstelle zum Signal Messenger ueber das signal_cli Paket in dbus daemon modus zur Verfuegung

=begin html

<a name="Signalbot"></a>
<h3>Signalbot</h3>
(en | <a href="commandref_DE.html#Signalbot">de</a>)
<ul>
	<a name="Signalbot"></a>
		provides an interface to the Signal Messenger, via signal_cli running as dbus daemon<br>
		The signal_cli package needs to be installed. See github for installation details on <a href="https://github.com/AsamK/signal-cli">signal-cli</a><br>
		Refer to this documentation on how to setup signal-cli in dbus daemon mode <a href="https://knx-user-forum.de/forum/supportforen/openhab/1139194-whisper-systems-signal-messenger-client-einrichten">only in german</a><br>
		<br><br>
		Supported functionality (mainly due to limitations of the signal-cli dbus interface:<br>
		<ul>
		<li>Send messages to individuals and/or groups with or without attachments</li>
		<li>Retrieve the list of joined groups in order to allow using group names when sending (automatically done when encountering an unknown group)</li>
		<br><b>What is the difference to the already existing SiSi:</b><br><br>
		<li>Works without forking a new thread, thus saving a lot of memory</li>
		<li>Groups are always translated to names instead of cryptic base64 encoding</li>
		<li>Contact name can be used if known. Names will be discovered when getting messages or initially sending to the phone number</li>
		<li>Interpretation FHEM/Perl round brackets () as commands which result can we used to dynamically create text or get streams for attachments e.g. SVG plots like in TelegramBot>/li>
		<b>Limitations:</b><br>
		<li>The whole setup, registration and eving joining groups has to be done from signal-cli since a lot of functionality is not supported (yet) via the Dbus interface</li>
		<li>Contacts need to be discovered and cannot be loaded (limitation of signal-cli), but existing list can be saved to a reading</li>
		<br>
		<br>
		</ul>
	<a name="SignalbotDefine"></a><br>
	<b>Define</b>
	<ul>
		<code>define &lt;name&gt; Signalbot</code><br>
		No arguments (for now)<br>
		<br>
	</ul>

	<a name="SignalbotSet"></a>
	<b>Set</b>
	<ul>
		<li><b>set &lt;name&gt; &lt;send&gt; [@&lt;Recipient1&gt; ... @&lt;RecipientN&gt;] [#&lt;GroupId1&gt; ... #&lt;GroupIdN&gt;] [&&lt;Attachment1&gt; ... &&lt;AttachmentN&gt;] [&lt;Text&gt;]</b><br>
			<a name="send"></a>
			<ul>
			<li>Use round brackets to let FHEM execute the content (e.g <code>&({plotAsPng('SVG_Temperatures')}</code></li>
			<li>If a recipient, group or attachment contains white spaces, the whole expression (including @ # or &) needs to be put in double quotes. Escape quotes with \"</li>
			<li>If the round brackets contain curly brackets to execute Perl commands, two semi-colons (;;) need to be used to seperate multiple commands and at the end</li>
			</ul>
		</li>
		<li>Note:<br>
			<a name="send2"></a>
			<ul>
			<li>Messages to multiple recipients will be sent as one message</li>
			<li>Messages to multiple groups or mixed with individual recipients will be sent in multiple messages</li>
			<li>Note the difference to SiSi: Groups are only marked with "#" and have to be real group names (like shown in the app)</li>
			<li>Attachments need to containt valid pathnames readable for the fhem user</li>
			<li>Recipients can be either contact names or phone numbers (starting with +). Since signal-cli only understand phone numbers, 
			Signalbot tries to translate known contact names from its cache and might fail to send the message if unable to decode the contact<br>
			<br>
			Example:<br>
			<code>set Signalbot send "@({my $var=\"Joerg\";; return $var;;})" #FHEM "&( {plotAsPng('SVG_Temperatures')} )" Here come the current temperature plot</code><br>
			</ul>
			<br>			
		</li>
		<a name="refreshGroups"></a>
		<li><b>set refreshGroups</b><br>
		Read the currently joined groups from Signal. Typically not necessary since groups get discovered on the fly. The list is saved in the reading "joinedGroups"<br>
		</li>
		<li><b>set saveContacts</b><br>
		<a name="saveContacts"></a>
		Save the internal list of discovered contact name to phone number conversions into the reading "contactList"<br>
		</li>
		<li><b>set reinit</b><br>
		<a name="reinit"></a>
		Re-Initialize the module. For testing purposes when module stops receiving or has other issues. Should not be necessary.<br>
		</li>
		<br>
	</ul>

	<a name="SignalbotAttr"></a>
	<b>Attributes</b>
	<ul>
		<br>
		<li>poll_interval<br>
			Set the polling interval in minutes to query new messages<br>
			Typically not required, since the module gets notified when new messages arrive.<br>
			Default: -, valid values: decimal number<br>
		</li>
		<br>
		<li><a href="#ignore">ignore</a></li>
		<li><a href="#do_not_notify">do_not_notify</a></li>
		<li><a href="#showtime">showtime</a></li>
	</ul>
	<br>
	<a name="SignalbotReadings"></a>
	<b>Readings</b>
	<ul>
		<br>
		<li>(prev)msgAttachment</li>
		Attachment(s) of the last received (or for history reasons the previous before). The path points to the storage in signal-cli and can be used to retrieve the attachment.<br>
		<li>(prev)msgGroupName</li>
		Group of the last message (or for history reasons the previous before). Empty if last message was a private message<br>
		<li>(prev)msgSender</li>
		Sender that sent the last message (or previous before) <br>
		<li>(prev)msgText</li>
		Content of the last message <br>
		<li>(prev)msgTimestamp</li>
		Time the last message was sent (a bit redundant, since all readings have a timestamp anyway<br>
		<li>sentMsg</li>
		Content of the last message that was sent from this module<br>
		<li>sentRecipient</li>
		Recipient of the last message that was sent<br>
		This is taken from the actual reply and will contain the last recipient that confirmed getting the message in case multiple recipients or group memebers got it<br>
		<li>sendMsgTimestamp</li>
		Timestamp the message was received by the recipient. Will show pending of not confirmed (likely only if even the Signal server did not get it)<br>
	<br>
</ul>

=end html

=begin html_DE

<a name="Signalbot"></a>
<h3>Signalbot</h3>
(<a href="commandref.html#Signalbot">en</a> | de)
<ul>
	<a name="Signalbot"></a>
		Bitte englische Dokumentation verwenden.</b><br>
	<a name="SignalbotDefine"></a><br>
	<b>Define</b>
	<ul>
		<code>define &lt;name&gt; Signalbot</code><br>
		Alles weitere wird über Attribute definiert.<br>
	</ul>

	<a name="SignalbotSet"></a>
	<b>Set</b>
	<ul>
	</ul>

	<a name="SignalbotAttr"></a>
	<b>Attribute</b>
	<ul>
		<li>poll_interval<br>
			Aktualisierungsintervall aller Werte in Minuten.<br>
			Standard: -, g&uuml;ltige Werte: Dezimalzahl<br><br>
		</li>
		<li><a href="#ignore">ignore</a></li>
		<li><a href="#do_not_notify">do_not_notify</a></li>
		<li><a href="#showtime">showtime</a></li>
	</ul>
	<br>
</ul>

=end html_DE

=cut
