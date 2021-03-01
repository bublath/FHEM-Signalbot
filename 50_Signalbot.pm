##############################################
# $Id:2.0 beta$
# Simple Interface to Signal CLI running as Dbus service
# Author: Adimarantis
# License: GPL
# Credits to FHEM Forum Users Quantum (SiSi Module) and Johannes Viegener (Telegrambot Module) for code fragments and ideas
# Requires signal_cli (https://github.com/AsamK/signal-cli) and Protocol::DBus to work
# Verbose levels
# 5 = Internal data and function calls
# 4 = User actions and results
# 3 = Error messages
package main;

use strict;
use warnings;
use Protocol::DBus::Client;
use Scalar::Util qw(looks_like_number);
use File::Temp qw( tempfile tempdir );
use Text::ParseWords;
use Encode;
use Data::Dumper;
use Time::HiRes qw( usleep );

eval "use Protocol::DBus;1" or my $DBus_missing = "yes";

my %sets = (
  "send" => "textField",
  "reinit" => "noArg",
  "setContact" => "textField",
  "createGroup" => "textField",		#Call updategroups with empty group parameter, mandatory name and optional avatar picture
  "invite" => "textField",			#Call updategroups with mandatory group name and mandatory list of numbers to join
  "block" => "textField",			#Call setContactBlocked or setGroupBlocked (one one at a time)
  "unblock" => "textField",			#Call setContactBlocked or setGroupBlocked (one one at a time)
  "updateGroup" => "textField",		#Call updategroups to rename a group and/or set avatar picture
  "quitGroup" => "textField",		#V0.8.1+
  "joinGroup" => "textField",		#V0.8.1+
  "updateProfile" => "textField"	#V0.8.1+
 );
 
 my %gets = (
  "contacts"      => "all,nonblocked",
  "groups"        => "all,active,nonblocked",
);

 my %signatures = (
	"setContactBlocked" 	=> "sb",
	"setGroupBlocked" 		=> "ayb",
	"updateGroup" 			=> "aysass",
	"updateProfile" 		=> "ssssb",
	"quitGroup" 			=> "s",
	"joinGroup"				=> "s",
	"sendEndSessionMessage" => "as",
	"sendGroupMessage"		=> "sasay",
	"sendNoteToSelfMessage" => "sas",
	"sendMessage" 			=> "sasas",
	"getContactName" 		=> "s",
	"setContactName" 		=> "ss",
	"getGroupIds" 			=> "aay",
	"getGroupName" 			=> "ay",
	"getGroupMembers" 		=> "ay",
	"listNumbers" 			=> "",
	"getContactNumber" 		=> "s",
	"isContactBlocked" 		=> "s",
	"isGroupBlocked" 		=> "ay",
	"version" 				=> "",
	"isMember"				=> "ay",
	"isRegistered" 			=> ""
);

sub Signalbot_Initialize($) {
  my ($hash) = @_;

  $hash->{DefFn}     = 	"Signalbot_Define";
  $hash->{InitFn}  	 =  'Signalbot_Init';
  $hash->{AttrFn}    = 	"Signalbot_Attr";
  $hash->{SetFn}     = 	"Signalbot_Set";
  $hash->{ReadFn}    = 	"Signalbot_Read";
  $hash->{NotifyFn}  =  'Signalbot_Notify';
  $hash->{StateFn}   =  "Signalbot_State";
  $hash->{GetFn}     = 	"Signalbot_Get";
  $hash->{UndefFn}   = 	"Signalbot_Undef";
  $hash->{MessageReceived} = "Signalbot_MessageReceived";
  $hash->{ReceiptReceived} = "Signalbot_ReceiptReceived";
  $hash->{version}		= "Signalbot_Version_cb";
  $hash->{updateGroup}  = "Signalbot_UpdateGroup_cb";
  $hash->{joinGroup}	= "Signalbot_UpdateGroup_cb";
  $hash->{listNumbers}	= "Signalbot_ListNumbers_cb";
  $hash->{AttrList}  = 	"IODev do_not_notify:1,0 ignore:1,0 showtime:1,0 ".
												"defaultPeer: ".
												"allowedPeer ".
												"babblePeer ".
												"babbleDev ".
												"babbleExclude ".
												"authTimeout ".
												"authDev ".
												"cmdKeyword ".
												"autoJoin:yes,no ".
												"$readingFnAttributes";
}
################################### Todo: Set or Attribute for Mode? Other sets needed?
sub Signalbot_Set($@) {					#

	my ( $hash, $name, @args ) = @_;

	### Check Args
	my $numberOfArgs  = int(@args);
	return "Signalbot_Set: No cmd specified for set" if ( $numberOfArgs < 1 );

	my $cmd = shift @args;
	my $version = $hash->{helper}{version};
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
		}
		return "Signalbot_Set: Unknown argument $cmd, choose one of " . join(" ", @cList);
	} # error unknown cmd handling

	#Pre-parse for " " embedded strings, except for "send" that does its own processing
	if ( $cmd ne "send") {
		@args=parse_line(' ',0,join(" ",@args));
	}
	
	if ( $cmd eq "setContact") {
		if (@args<2 ) {
			return "Usage: set ".$hash->{NAME}." setContact <number> <nickname>";
		} else {
			my $number = shift @args;
			my $nickname = join (" ",@args);
			my $ret=Signalbot_setContactName($hash,$number,$nickname);
			return $ret if defined $ret;
		}
		return undef;
	} elsif ( $cmd eq "createGroup") {
		if (@args<1 || @args>2 ) {
			return "Usage: set ".$hash->{NAME}." createGroup <group name> &[path to thumbnail]";
		} else {
			my $ret=Signalbot_updateGroup($hash,@args);
			return $ret if defined $ret;
		}
		return undef;
	} elsif ( $cmd eq "updateProfile") {
		if ($version<=800) {
			return "updateProfile requires signal-cli 0.8.1 or higher";
		}
		if (@args<1 || @args>2 ) {
			return "Usage: set ".$hash->{NAME}." updateProfile <new name> &[path to thumbnail]";
		} else {
			my $ret=Signalbot_updateProfile($hash,@args);
			return $ret if defined $ret;
		}
		return undef;
	} elsif ( $cmd eq "quitGroup") {
		if ($version<=800) {
			return $cmd." requires signal-cli 0.8.1 or higher";
		}
		if (@args!=1) {
			return "Usage: set ".$hash->{NAME}." ".$cmd." <group name>";
		}
		my $ret;
		my @group=Signalbot_getGroup($hash,$args[0]);
		return join(" ",@group) unless @group>1;
		Signalbot_Call($hash,"quitGroup",\@group);
		return undef;
	} elsif ( $cmd eq "joinGroup") {
		if (@args!=1) {
			return "Usage: set ".$hash->{NAME}." ".$cmd." <group link>";
		}
		return Signalbot_join($hash,$args[0]);
	} elsif ( $cmd eq "block" || $cmd eq "unblock") {
		if (@args!=1) {
			return "Usage: set ".$hash->{NAME}." ".$cmd." <group name>|<contact>";
		} else {
			my $name=shift @args;
			my $ret=Signalbot_setBlocked($hash,$name,($cmd eq "block"?1:0));
			return $ret if defined $ret;
		}
		return undef;
	} elsif ( $cmd eq "updateGroup") {
		if (@args<1 || @args>3 ) {
			return "Usage: set ".$hash->{NAME}." updateGroup <group name> #[new name] &[path to thumbnail]";
		} else {
			my $ret=Signalbot_updateGroup($hash,@args);
			return $ret if defined $ret;
		}
		return undef;
	} elsif ( $cmd eq "invite") {
		if (@args < 2 ) {
			return "Usage: set ".$hash->{NAME}." invite <group name> <contact1> [<contact2] ...]";
		} else {
			my $groupname = shift @args;
			my $ret=Signalbot_invite($hash,$groupname,@args);
			return $ret if defined $ret;
		}
		return undef;
	} elsif ( $cmd eq "send") {
		return "Usage: set ".$hash->{NAME}." send [@<Recipient1> ... @<RecipientN>] [#<GroupId1> ... #<GroupIdN>] [&<Attachment1> ... &<AttachmentN>] [<Text>]" if ( @args==0); 

		my @recipients = ();
		my @groups = ();
		my @attachments = ();
		my $message = "";
		#To allow spaces in strings, join string and split it with parse_line that will honor spaces embedded by double quotes
		my $fullstring=join(" ",@args);
		my $bExclude=AttrVal($hash->{NAME},"babbleExclude",undef);
		if ($bExclude && $fullstring =~ /$bExclude(.*)/s) {  #/s required so newlines are included in match
			#Extra utf Encoding marker)
			$fullstring=encode_utf8($1);
			Log3 $hash->{NAME}, 4 , $hash->{NAME}.": Extra UTF8 encoding of:$fullstring:\n";
		}
		eval { $fullstring=decode_utf8($fullstring); };
			Log3 $hash->{NAME}, 3 , $hash->{NAME}.": Error from decode" if $@;
			
		Log3 $hash->{NAME}, 3 , $hash->{NAME}.": Before parse:$fullstring:\n";
		my $tmpmessage = $fullstring =~ s/\\n/\x0a/r;
		my @args=parse_line(' ',0,$tmpmessage);
		
		while(my $curr_arg = shift @args){
			if($curr_arg =~ /^\@([^#].*)$/){	#Compatbility with SiSi - also allow @# as groupname
				push(@recipients,$1);
			}elsif($curr_arg =~ /^\@#(.*)$/){ 	#Compatbility with SiSi - also allow @# as groupname
				push(@groups,$1);
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
		return "Not enough arguments. Specify a Recipient, a GroupId or set the defaultPeer attribute" if( (@recipients==0) && (@groups==0) && (!defined $defaultPeer) );

		#Check for embedded fhem/perl commands
		my $err;
		($err, @recipients) = SignalBot_replaceCommands($hash,@recipients);
		if ($err) { return $err; }
		($err, @groups) = SignalBot_replaceCommands($hash,@groups);
		if ($err) { return $err; }
		($err, @attachments) = SignalBot_replaceCommands($hash,@attachments);
		if ($err) { return $err; }
		
		#Am Schluss eine Schleife über die Attachments und alle die mit /tmp/signalbot anfangen löschen (unlink)

		if ((defined $defaultPeer) && (@recipients==0) && (@groups==0)) {

			my @peers = split(/,/,$defaultPeer);
			while(my $curr_arg = shift @peers){
				if($curr_arg =~ /^#/){
					push(@groups,$curr_arg);
				} else {
					push(@recipients,$curr_arg);
				}
			}
		}
		return "Specify either a message text or an attachment" if((@attachments==0) && (@args==0));

		$message = join(" ", @args);
		if (@attachments>0) {
			#create copy in /tmp to mitigate incomplete files and relative paths in fhem
			my @newatt;
			foreach my $file (@attachments) {
				if ( -e $file ) {
					if ($file =~ /[tmp\/signalbot]/) {
						$file =~ /^.*?\.([^.]*)?$/;
						my $type = $1;
						my $tmpfilename="/tmp/signalbot".gettimeofday().".".$type;
						copy($file,$tmpfilename);
						push @newatt, $tmpfilename;
					} else {
						push @newatt, $file;
					}
				} else {
					return "File not found: $file";
				}
			}
			@attachments=@newatt;
		}

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
		my $ret = Signalbot_setup($hash);
		$hash->{STATE} = $ret if defined $ret;
	}
	return undef;
}
################################### 
sub Signalbot_Get($@) {
	my ($hash, $name, @args) = @_;
	
	my $numberOfArgs  = int(@args);
	return "Signalbot_Set: No cmd specified for get" if ( $numberOfArgs < 1 );

	my $cmd = shift @args;

	if (!exists($gets{$cmd}))  {
		my @cList;
		foreach my $k (keys %gets) {
			my $opts = undef;
			$opts = $gets{$k};

			if (defined($opts)) {
				push(@cList,$k . ':' . $opts);
			} else {
				push (@cList,$k);
			}
		}
		return "Signalbot_Get: Unknown argument $cmd, choose one of " . join(" ", @cList);
	} # error unknown cmd handling
	
	my $version = $hash->{helper}{version};
	my $arg = shift @args;
	if ($gets{$cmd} =~ /$arg/) {
		if ($cmd eq "contacts") {
			if ($version<=800) {
				return "Signal-cli 0.8.1+ required for this functionality";
			}
			Signalbot_CallS($hash,"listNumbers");
			my $ret="List of known contacts:\n\n";
			my $format="%-16s|%-30s|%-6s\n";
			$ret.=sprintf($format,"Number","Name","Blocked");
			$ret.="\n";
			foreach my $number (keys %{$hash->{helper}{contacts}}) {
				my $blocked=Signalbot_CallS($hash,"isContactBlocked",$number);
				my $name=$hash->{helper}{contacts}{$number};
				if (! ($number =~ /^\+/) ) { $number="Unknown"; }
				if ($arg eq "all" || $blocked==0) {
					$ret.=sprintf($format,$number,$name,$blocked==1?"yes":"no");
				}
			}
			return $ret;
		} elsif ($cmd eq "groups") {
			Signalbot_refreshGroups($hash);
			if ($version<=800) {
				return "Signal-cli 0.8.1+ required for this functionality";
			}
			my $ret="List of known groups:\n\n";
			my $format="%-16s|%-6s|%-7s|%-30s\n";
			$ret.=sprintf($format,"Group","Active","Blocked","Members");
			$ret.="\n";
			foreach my $groupid (keys %{$hash->{helper}{groups}}) {
				my $blocked=$hash->{helper}{groups}{$groupid}{blocked};
				my $active=$hash->{helper}{groups}{$groupid}{active};
				my $group=$hash->{helper}{groups}{$groupid}{name};
				my @groupID=split(" ",$groupid);
				my $mem=Signalbot_CallS($hash,"getGroupMembers",\@groupID);
				my @members=();;
				foreach (@$mem) {
					push @members,Signalbot_getContactName($hash,$_);
				}
				if ($arg eq "all" || ($active==1 && $arg eq "active") || ($active==1 && $blocked==0 && $arg eq "nonblocked") ) {
					$ret.=sprintf($format,$group,$active==1?"yes":"no",$blocked==1?"yes":"no",join(",",@members));
				}
			}
			return $ret;
		}
	} else {
		return "Signalbot_Set: Unknown argument for $cmd : $arg";
	}
	return undef;
}

sub Signalbot_command($@){
	my ($hash, $sender, $message) = @_;
	
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Check Command $sender $message";
	my $timeout=AttrVal($hash->{NAME},"authTimeout",0);
	return if $timeout==0;
	my $device=AttrVal($hash->{NAME},"authDev",undef);
	return unless defined $device;
	my $cmd=AttrVal($hash->{NAME},"cmdKeyword",undef);
	return unless defined $cmd;
	my @arr=();
	if ($message =~ /^$cmd(.*)/) {
		$cmd=$1;
		Log3 $hash->{NAME}, 5, $hash->{NAME}.": Command received:$cmd";
		my @cc=split(" ",$cmd);
		if ($cc[0] =~ /\d+$/) {
			#This could be a token
			my $token=shift @cc;
			my $restcmd=join(" ",@cc);
			my $ret = gAuth($device,$token);
			if ($ret == 1) {
				Log3 $hash->{NAME}, 5, $hash->{NAME}.": Token valid for sender $sender for $timeout seconds";
				$hash->{helper}{auth}{$sender}=1;
				#Remove potential old timer so countdown start from scratch
				RemoveInternalTimer("$hash->{NAME} $sender");
				InternalTimer(gettimeofday() + $timeout, 'SignalBot_authTimeout', "$hash->{NAME} $sender", 0);
				Signalbot_sendMessage($hash,$sender,"","You have control for ".$timeout."s");
				$cmd=$restcmd;
			} else {
				Log3 $hash->{NAME}, 3, $hash->{NAME}.": Invalid token for sender $sender";
				$hash->{helper}{auth}{$sender}=0;
				Signalbot_sendMessage($hash,$sender,"","Invalid token");
				return 1;
			}
		}
		return 1 if $cmd eq "";
		if ($hash->{helper}{auth}{$sender}==1) {
			Log3 $hash->{NAME}, 4, $hash->{NAME}.": $sender executes command $cmd";
			my $error = AnalyzeCommand($hash, $cmd);
			if (defined $error) {
				Signalbot_sendMessage($hash,$sender,"",$error);
			} else {
				Signalbot_sendMessage($hash,$sender,"","Done");
			}
		} else {
			Signalbot_sendMessage($hash,$sender,"","You are not authorized to execute commands");
		}
		return 1;
	}
   return undef;
}

#Reset auth after timeout
sub SignalBot_authTimeout($@) {
	my ($val)=@_;
	my ($name,$sender)=split(" ",$val);
	my $hash = $defs{$name};
	$hash->{helper}{auth}{$sender}=0;
}

sub Signalbot_MessageReceived ($@) {
	my ($hash,$timestamp,$source,$groupID,$message,$attachments) = @_;

	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Message Callback";

	my $atr="";
	my @att=@$attachments;
	foreach (@att) {
		$atr.= $_." " if defined $_;
	}	

	if ($message eq "" && @att==0) {
		#Empty messages happens e.g. if someone leaves a group - ignore
		return;
	}

	my @groups=@$groupID;
	my $grp="";
	foreach (@groups) {
		$grp.=$_." " if defined $_;
	} 	

	my $group=Signalbot_translateGroup($hash,trim($grp));
	my $sender=Signalbot_getContactName($hash,$source);
	
	if (!defined $sender) {
		Log3 $hash->{NAME}, 3, $hash->{NAME}.":Issue with resolving contact $source\n";
		$sender=$source;
	}
	
	#Check if for command execution
	my $auth=Signalbot_command($hash,$source,$message);
	return if defined $auth;
	
	my $join=AttrVal($hash->{NAME},"autoJoin","no");
	if ($join eq "yes") {
		if ($message =~ /^https:\/\/signal.group\//) {
			return Signalbot_join($message);
		}
	}
	
	my $senderRegex = quotemeta($sender);
	#Also check the untranslated sender names in case these were used in allowedPeer instead of the real names
	my $sourceRegex = quotemeta($source);
	my $groupIdRegex = quotemeta($group);
	my $allowedPeer = AttrVal($hash->{NAME},"allowedPeer",undef);
	
	if(!defined $allowedPeer || $allowedPeer =~ /^.*$senderRegex.*$/ || $allowedPeer =~ /^.*$sourceRegex.*$/ || ($groupIdRegex ne "" && $allowedPeer =~ /^.*$groupIdRegex.*$/)) {
		#Copy previous redings to keep history of on message
		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "prevMsgTimestamp", ReadingsVal($hash->{NAME}, "msgTimestamp", undef)) if defined ReadingsVal($hash->{NAME}, "msgTimestamp", undef);
		readingsBulkUpdate($hash, "prevMsgText", ReadingsVal($hash->{NAME}, "msgText", undef)) if defined ReadingsVal($hash->{NAME}, "msgText", undef);
		readingsBulkUpdate($hash, "prevMsgSender", ReadingsVal($hash->{NAME}, "msgSender", undef)) if defined ReadingsVal($hash->{NAME}, "msgSender", undef);
		readingsBulkUpdate($hash, "prevMsgGroupName", ReadingsVal($hash->{NAME}, "msgGroupName", undef)) if defined ReadingsVal($hash->{NAME}, "msgGroupName", undef);
		readingsBulkUpdate($hash, "prevMsgGroupId", ReadingsVal($hash->{NAME}, "msgGroupId", undef)) if defined ReadingsVal($hash->{NAME}, "msgGroupId", undef);
		readingsBulkUpdate($hash, "prevMsgAttachment", ReadingsVal($hash->{NAME}, "msgAttachment", undef)) if defined ReadingsVal($hash->{NAME}, "msgAttachment", undef);
		readingsEndUpdate($hash, 0);

		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "msgAttachment", trim($atr));
		readingsBulkUpdate($hash, "msgTimestamp", strftime("%d-%m-%Y %H:%M:%S", localtime($timestamp/1000)));
		readingsBulkUpdate($hash, "msgText", $message);
		readingsBulkUpdate($hash, "msgSender", $sender);
		readingsBulkUpdate($hash, "msgGroupName", $group);
		my $auth=0;
		if (defined $hash->{helper}{auth}{$source}) { $auth=$hash->{helper}{auth}{$source}; }
		readingsBulkUpdate($hash, "msgAuth", $auth);
		readingsEndUpdate($hash, 1);

		my $bDevice=AttrVal($hash->{NAME},"babbleDev",undef);
		my $bPeer=AttrVal($hash->{NAME},"babblePeer",undef);
		my $bExclude=AttrVal($hash->{NAME},"babbleExclude",undef);
		
		if ($bExclude && $message =~ /$bExclude/) {
			Log3 $hash->{NAME}, 5, $hash->{NAME}.": Message matches BabbleExclude, skipping BabbleCall";
			return;
		}
		
		#Just pick one sender in den Priority: group, named contact, number, babblePeer
		my $replyPeer=undef;
		$replyPeer=$sourceRegex if defined $sourceRegex;
		$replyPeer=$senderRegex if defined $senderRegex;
		$replyPeer="#".$groupIdRegex if defined $groupIdRegex;
		
		#Activate Babble integration, only if sender or sender group is in babblePeer 
		if (defined $bDevice && defined $bPeer && defined $replyPeer) {
			if ($bPeer =~ /^.*$senderRegex.*$/ || $bPeer =~ /^.*$sourceRegex.*$/ || ($groupIdRegex ne "" && $bPeer =~ /^.*$groupIdRegex.*$/)) {
				Log3 $hash->{NAME}, 4, $hash->{NAME}.": Calling Babble for $message ($replyPeer)";
				my $rep=Babble_DoIt($bDevice,$message,$replyPeer);
			}
		}
		Log3 $hash->{NAME}, 4, $hash->{NAME}.": Message from $sender : $message processed";
	} else {
		Log3 $hash->{NAME}, 4, $hash->{NAME}.": Message from $sender : $message ignored due to allowedPeer";
	}
}

sub Signalbot_ReceiptReceived {
	my ($hash, $timestamp, $source) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Signalbot_receive_callback $timestamp $source ";
	my $sender=Signalbot_getContactName($hash,$source);
	
	if (!defined $sender) {
		Log3 $hash->{NAME}, 3, $hash->{NAME}.":Issue with resolving contact $source\n";
		$sender=$source;
	}
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "sentMsgRecipient", $sender);
	readingsBulkUpdate($hash, 'sentMsgTimestamp', strftime("%d-%m-%Y %H:%M:%S", localtime($timestamp/1000)));
	readingsEndUpdate($hash, 0);
}

sub Signalbot_SyncMessageReceived {
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
		delete $hash->{helper}{dbus} if defined $hash->{helper}{dbus};
		delete $hash->{helper}{dbuss} if defined $hash->{helper}{dbuss};
		close $hash->{FD} if defined $hash->{FD};
		delete $hash->{FD};
		$selectlist{"$name.dbus"} = undef;
		$hash->{STATE}="Disconnected";
	}; 
	if ($@) {
		Log3 $name, 4, "Error in disconnect:".$@;
	}
	Log3 $name, 5, "Disconnected and cleaned up";
}

# Initialize Connect and use FHEM select loop to wait for finish
sub Signalbot_setup($@){
	my ($hash) = @_;
	my $name=$hash->{NAME};
	if (defined $hash->{helper}{dbus}) {
		#Reinitialize everything to avoid double callbacks and other issues
		Signalbot_disconnect($hash);
	}	
	delete $hash->{helper}{contacts};
	my $dbus = Protocol::DBus::Client::system();
	if (!defined $dbus) {
		Log3 $name, 3, $hash->{NAME}.": Error while initializing Dbus";
		$hash->{helper}{dbus}=undef;
		return "Error setting up DBUS - is Protocol::Dbus installed?";
	}
	$hash->{helper}{dbus}=$dbus;
	$dbus->initialize();
	#Second instance for syncronous calls
	my $dbus2 = Protocol::DBus::Client::system();
	if (!defined $dbus2) {
		Log3 $name, 3, $hash->{NAME}.": Error while initializing Dbus";
		$hash->{helper}{dbuss}=undef;
		return "Error setting up DBUS - is Protocol::Dbus installed?";
	}
	$hash->{helper}{dbuss}=$dbus2;
	$dbus2->initialize();
	delete $hash->{helper}{init};
	$hash->{helper}{serial}{0}="List of DBus serial replies";
	#$dbus->blocking(0);
	#Get filehandle
	$hash->{FD}=$dbus->fileno();
	$selectlist{"$name.dbus"} = $hash;
	$hash->{STATE}="Connecting";
	return undef;
}

# After Dbus init successfully came back
sub Signalbot_setup2($@) {
	my ($hash) = @_;
	my $name=$hash->{NAME};
	my $dbus=$hash->{helper}{dbus};
	if (!defined $dbus) {
		return "Error: Dbus not initialized";
	}
	if (!$dbus->initialize()) { $dbus->init_pending_send(); return; }
	$hash->{helper}{init}=1;
	#Initialize Signal listener
	$dbus->send_call(
            path        => '/org/freedesktop/DBus',
            interface   => 'org.freedesktop.DBus',
            member      => 'AddMatch',
            destination => 'org.freedesktop.DBus',
            signature   => 's',
            body        => [ "type='signal',path='/org/asamk/Signal'" 
			],
        );	

	$hash->{STATE}="Connected";
	
	#Restore contactlist into internal hash
	my $clist=ReadingsVal($hash->{NAME}, "contactList",undef);
	if (defined $clist) {
		my @contacts=split(",",$clist);
		foreach my $val (@contacts) {
			my ($k,$v) = split ("=",$val);
			$hash->{helper}{contacts}{$k}=$v;
		}
	}
	Signalbot_Call($hash,"version");
	return undef;
}

#Async Callback for getting Version
sub Signalbot_Version_cb($@) {
	my ($hash,$version) = @_;
	if ($version eq "0.8.0") {$version="0.8.1";} #for beta release
	my @ver=split('\.',$version);
	#to be on the safe side allow 2 digits for lowest version number, so 0.8.0 results to 800
	$hash->{helper}{version}=$ver[0]*1000+$ver[1]*100+$ver[2];
	if ($hash->{helper}{version}>800) {
		readingsSingleUpdate($hash, 'signalVersion', $version,0);
	}  else {
		#No version info for 0.8.0 and older
		readingsSingleUpdate($hash, 'signalVersion', "0.8.0 or older",0);
	}
	if($hash->{helper}{version}>800) {
		Signalbot_Call($hash,"listNumbers");
	}
}

#Async Callback after updating Groups (change/invite/join)
sub Signalbot_UpdateGroup_cb($@) {
	my ($hash) = @_;
	Signalbot_refreshGroups($hash);
}

#Async Callback after getting list of Numbers, results will also be filled asynchronous
sub Signalbot_ListNumbers_cb($@) {
	my ($hash,$rec) = @_;
	my @numbers=@$rec;
	foreach (@numbers) {
		my $contact=Signalbot_getContactName($hash,$_);
	}
}

# Dbus syncronous (request->reply) Call
sub Signalbot_CallS($@) {
	my ($hash,$function,@args) = @_;
	my $dbus=$hash->{helper}{dbuss};
	if (!defined $dbus) {
		readingsSingleUpdate($hash, 'lastError', "Error: Dbus not initialized",1);
		return undef;
	}
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Sync Dbus Call: $function Args:".((@args==0)?"empty":join(",",@args));
	my $sig="";
	my $body="";
	my $got_response = 0;
	if (@args>0) {
		$sig=$signatures{$function};
		$body=\@args;
	}
	$dbus->send_call(
		path => '/org/asamk/Signal',
		interface => 'org.asamk.Signal',
		signature => $sig,
		body => $body,
		destination => 'org.asamk.Signal',
		member => $function,
	) ->then( sub {
		$got_response = 1;
		} 
	) -> catch ( sub () {
		Log3 $hash->{NAME}, 4, $hash->{NAME}.": Sync Error for: $function";
		my $msg = shift;
		if (!defined $msg) {
			readingsSingleUpdate($hash, 'lastError', "Fatal Error in $function: empty message",1);
			return;
		}
		my $sig = $msg->get_header('SIGNATURE');
		if (!defined $sig) {
			readingsSingleUpdate($hash, 'lastError', "Error in $function: message without signature",1);
			return;
		}
		$got_response = -1;
		}
	);

	my $counter=5;
	while ($counter>0) {
		my $msg=$dbus->get_message();
		my $sig = $msg->get_header('SIGNATURE');
		if (!defined $sig) {
			#Empty signature is probably a reply from a function without return data -> nothing to do
			next;
		}
		my $b=$msg->get_body()->[0];
		if ($got_response==-1) {
			#Error Case
			readingsSingleUpdate($hash, 'lastError', "Error in $function:".$b,1);
			return undef;
		}
		if ($got_response==1) {
			return $b
		}
		$counter--;
	}
}

# Generic Dbus Call method
#e.g.:
# $hash, "sendMessage", ("Message",\@att,\@rec)
sub Signalbot_Call($@) {
	my ($hash,$function,@args) = @_;
	my $dbus=$hash->{helper}{dbus};
	if (!defined $dbus) {
		readingsSingleUpdate($hash, 'lastError', "Error: Dbus not initialized",1);
		return undef;
	}
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": ASync Dbus Call: $function Args:".((@args==0)?"empty":join(",",@args));
	my $sig="";
	my $body="";
	if (@args>0) {
		$sig=$signatures{$function};
		$body=\@args;
	}
	$dbus->send_call(
		path => '/org/asamk/Signal',
		interface => 'org.asamk.Signal',
		signature => $sig,
		body => $body,
		destination => 'org.asamk.Signal',
		member => $function,
	) ->then ( sub () {
		my $msg = shift;
		my $sig = $msg->get_header('SIGNATURE');
		if (!defined $sig) {
			#Empty signature is probably a reply from a function without return data -> nothing to do
			return;
		}
		my $b=$msg->get_body();
		my 	@body=@$b;
		Log3 $hash->{NAME}, 5, $hash->{NAME}.": ASync Calling: $function Args:".join(",",@body);
		CallFn($hash->{NAME},$function,$hash,@body);
		}
	) -> catch ( sub () {
		Log3 $hash->{NAME}, 4, $hash->{NAME}.": ASync Error for: $function";
		my $msg = shift;
		if (!defined $msg) {
			readingsSingleUpdate($hash, 'lastError', "Fatal Error in $function: empty message",1);
			return;
		}
		my $sig = $msg->get_header('SIGNATURE');
		if (!defined $sig) {
			readingsSingleUpdate($hash, 'lastError', "Error in $function: message without signature",1);
			return;
		}
		#Handle Error here and mark Serial for mainloop to ignore
		my $b=$msg->get_body()->[0];
		readingsSingleUpdate($hash, 'lastError', "Error in $function:".$b,1);
		}
	); 
}

sub Signalbot_Read($@){
	my ($hash) = @_;
	if (!defined $hash->{helper}{init}) { Signalbot_setup2($hash); return;};

	my $dbus=$hash->{helper}{dbus};
	if (!defined $dbus) {
		return "Error: Dbus not initialized";
	}
	my $msg="";
	my $counter=5;
	while (defined $msg || $counter>0) {
		$dbus->blocking(0);
		$msg = $dbus->get_message();
		if ($msg) {
			#Signal handling
			my $callback = $msg->get_header('MEMBER');
			if (defined $callback) {
				my $b=$msg->get_body();
				my @body=@$b;
				if ($callback eq "MessageReceived" || $callback eq "ReceiptReceived" || $callback eq "SyncMessageReceived") {
					my $func="Signalbot_$callback";
					Log3 $hash->{NAME}, 5, $hash->{NAME}.": Sync Callback: $callback Args:".join(",",@body);
					CallFn($hash->{NAME},$callback,$hash,@body);
				} elsif ($callback eq "NameAcquired") {
					Log3 $hash->{NAME}, 5, $hash->{NAME}.": My Dbus Name is $body[0]";
					$hash->{helper}{init}=$body[0];
				} else {
					Log3 $hash->{NAME}, 4, $hash->{NAME}.": Unknown callback $callback";
				}
			}
		}
		$counter--; usleep(10000); 
	}
}

sub Signalbot_getContactName($@) {
	my ( $hash,$number) = @_;

	#check internal inventory
	my $contact=$hash->{helper}{contacts}{$number};

	#if not found, ask Signal
	if (!defined $contact || $contact eq "") {
		#In this case it needs to stay synchronous, but should rarely be called due to caching
		$contact = Signalbot_CallS($hash,"getContactName",$number);
		#Add to internal inventory
		if (!defined $contact) {return "";}
		$hash->{helper}{contacts}{$number}=$contact;
	}
	if ($contact eq "") {return $number;}
	return $contact;
}

#Allow create only for new groups
sub Signalbot_updateGroup($@) {
	my ( $hash,@args) = @_;
	my $groupname = shift @args;
	if ($groupname =~ /^#(.*)/) {
		$groupname=$1;
	}
	my $rename;
	my $avatar;
	while (my $next = shift @args) {
		if ($next =~ /^#(.*)/) {
			$rename=$1;
		}
		if ($next =~ /^\&(.*)/) {
			$avatar=$1;
		}
	}
	if (defined $avatar) {
		return "Can't find file $avatar" unless ( -e $avatar);
		Log3 $hash->{NAME}, 4, $hash->{NAME}.": updateGroup Avatar $avatar";
		my $size = -s $avatar;
		return "Please reduce the size of your group picture to <2MB" if ($size>2000000);
	}
	my @groupID=Signalbot_getGroup($hash,$groupname);
	#Rename case: Group has to exist
	if (defined $rename) {
		if (@groupID==1) {
			return "Group $groupname does not exist";
		} else {
			Log3 $hash->{NAME}, 4, $hash->{NAME}.": renameGroup $groupname to $rename";
			$groupname=$rename;
		}
	}
	#Create case (no rename and no avatar): Group cannot exist
	if (!defined $rename && !defined $avatar) {
		return "Group $groupname already exists" if @groupID>1;
		Log3 $hash->{NAME}, 4, $hash->{NAME}.": createGroup $groupname";
	}
	if (@groupID==1) { @groupID=();	}
	if (!defined $avatar) { $avatar=""; }
	my @members=(); #only set for invite
	Signalbot_Call($hash,"updateGroup",\@groupID,$groupname,\@members,$avatar);
}

sub Signalbot_updateProfile($@) {
	my ($hash,@args) = @_;
	my $avatar;
	my $newname;
	while (my $next = shift @args) {
		if ($next =~ /^\&(.*)/) {
			$avatar=$1;
		} else {
			$newname=$next;
		}
	}
	if (defined $avatar) {
		return "Can't find file $avatar" unless ( -e $avatar);
		Log3 $hash->{NAME}, 4, $hash->{NAME}.": updateProfile Avatar $avatar";
		my $size = -s $avatar;
		return "Please reduce the size of your group picture to <2MB" if ($size>2000000);
	} else { $avatar=""; }
	#new name, about, emoji, avatar, removeAvatar
	Signalbot_Call($hash,"updateProfile",$newname,"","",$avatar,0);
}

sub Signalbot_join($@) {
	my ( $hash,$grouplink) = @_;
	my $version = $hash->{helper}{version};
	if ($version<=800) {
		return "Joining groups requires signal-cli 0.8.1 or higher";
	}
	Signalbot_Call($hash,"joinGroup",$grouplink);
}

sub Signalbot_invite($@) {
	my ( $hash,$groupname,@contacts) = @_;

	my @members=();
	while (@contacts) {
		my $contact=shift @contacts;
		my $number=Signalbot_translateContact($hash,$contact);
		return "Unknown Contact" unless defined $number;
		push @members,$number;
	}
	
	my @group=Signalbot_getGroup($hash,$groupname);
	return join(" ",@group) unless @group>1;
	
	Log3 $hash->{NAME}, 4, $hash->{NAME}.": Invited ".join(",",@contacts)." to $groupname";
	Signalbot_Call($hash,"updateGroup",\@group,"",\@members,"");
}

sub Signalbot_setBlocked($@) {
	my ( $hash,$name,$blocked) = @_;
	if ($name =~ /^#(.*)/) {
		my @group=Signalbot_getGroup($hash,$1);
		return join(" ",@group) unless @group>1;
		Log3 $hash->{NAME}, 4, $hash->{NAME}.": ".($blocked==0?"Un":"")."blocked $name";
		Signalbot_Call($hash,"setGroupBlocked",\@group,$blocked);
	} else {
		my $number=Signalbot_translateContact($hash,$name);
		return "Unknown Contact" unless defined $number;
		Log3 $hash->{NAME}, 4, $hash->{NAME}.": ".($blocked==0?"Un":"")."blocked $name ($number)";
		my $ret=Signalbot_Call($hash,"setContactBlocked",$number,$blocked);
	}
	return undef;
}

sub Signalbot_setContactName($@) {
	my ( $hash,$number,$name) = @_;

	if (!defined $number || !defined $name || $number eq "" || $name eq "") {
		return "setContactName: Number and Name required";
	}
	if ($number =~ /^[^\+].*/) {
		return "setContactName: Invalid number";
	}
	$hash->{helper}{contacts}{$number}=$name;

	Signalbot_Call($hash,"setContactName",$number,$name);
	return undef;
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
	
	my $group=$hash->{helper}{groups}{$groupID}{name};
	return $group if defined $group;

	#Group not found, so check if we simply don't know it yet
	Signalbot_refreshGroups($hash) if ($init_done);
	#And try again
	$group=$hash->{helper}{groups}{$groupID}{name};
	return $group if defined $group;
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

sub Signalbot_refreshGroups($@) {
	my ( $hash ) = @_;
	my $ret= Signalbot_CallS($hash,"getGroupIds");
	my @groups = @$ret;
	my @grouplist;
	foreach (@groups) {
		my @group=@$_;
		my $groupname = Signalbot_CallS($hash,"getGroupName",\@group);
		my $groupid = join(" ",@group);
		$hash->{helper}{groups}{$groupid}{name}=$groupname;	
		Log3 $hash->{NAME}, 5, "found group ".$groupname; 
		if($hash->{helper}{version}>800) {
			my $active = Signalbot_CallS($hash,"isMember",\@group);
			$hash->{helper}{groups}{$groupid}{active}=$active;
			my $blocked = Signalbot_CallS($hash,"isGroupBlocked",\@group);
			$hash->{helper}{groups}{$groupid}{blocked}=$blocked;
			if ($blocked==1) {
				$groupname="(".$groupname.")";
			}
			if ($active==1) {
				push @grouplist,$groupname;
			}
		}
	}
	readingsSingleUpdate($hash, 'joinedGroups', join(",",@grouplist),0);
	return undef;
}

sub Signalbot_sendMessage($@) {
	my ( $hash,$rec,$att,$mes ) = @_;
	Log3 $hash->{NAME}, 4, $hash->{NAME}.": sendMessage called for $rec:$att:$mes"; 

	my @recorg= split(/,/,$rec);
	my @attach=split(/,/,$att);
	my @recipient=();
	foreach (@recorg) {
		my $trans=Signalbot_translateContact($hash,$_);
		return "Unknown recipient ".$_ unless defined $trans;
		push @recipient, $trans;
	}
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "sentMsg", encode_utf8($mes));
	readingsBulkUpdate($hash, 'sentMsgTimestamp', "pending");
	readingsEndUpdate($hash, 0);
	Signalbot_Call($hash,"sendMessage",$mes,\@attach,\@recipient); 
}

#get the identifies (list of hex codes) for a group based on the name
#Check error with int(@)=1
sub Signalbot_getGroup($@) {
	my ($hash,$rec) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": getGroup $rec";
	if ( $rec =~ /^#(.*)/) {
		$rec=$1;
	}
	my $group;
	foreach my $groupid (keys %{$hash->{helper}{groups}}) {
		$group=$hash->{helper}{groups}{$groupid}{name};
		return split(" ",$groupid) if (defined $group && $group eq $rec);
	}
	Signalbot_refreshGroups($hash);
	foreach my $groupid (keys %{$hash->{helper}{groups}}) {
		$group=$hash->{helper}{groups}{$groupid}{name};
		return split(" ",$groupid) if (defined $group && $group eq $rec);
	}
	return "Unknown group ".$rec." please check or refresh group list";
}

sub Signalbot_sendGroupMessage($@) {
	my ( $hash,$rec,$att,$mes ) = @_;
	Log3 $hash->{NAME}, 4, $hash->{NAME}.": sendGroupMessage called for $rec:$att:$mes"; 

	$rec=~s/#//g;
	my @recipient= split(/,/,$rec);
	if (@recipient>1) { return "Can only send to one group at once";}
	my @attach=split(/,/,$att);
	my @arr=Signalbot_getGroup($hash,$rec);
	return join(" ",@arr) unless @arr>1;

	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "sentMsg", $mes);
	readingsBulkUpdate($hash, 'sentMsgTimestamp', "pending");
	readingsEndUpdate($hash, 0);

	Signalbot_Call($hash,"sendGroupMessage",$mes,\@attach,\@arr); 
}

################################### 
sub Signalbot_Attr(@) {					#
	my ($command, $name, $attr, $val) = @_;
	my $hash = $defs{$name};
	my $msg = undef;

	if($attr eq "allowedPeer") {
	#Take over as is
	return undef;
	}	elsif($attr eq "babbleExclude") {
	#Take over as is
	return undef;
	} elsif($attr eq "babblePeer") {
	#Take over as is
	my $bDevice=AttrVal($hash->{NAME},"babbleDev",undef);
	if (!defined $bDevice && $init_done) {
		foreach my $dev ( sort keys %main::defs ) {
			if ($defs{$dev}->{TYPE} eq "Babble") {
				CommandAttr(undef,"$name babbleDev $dev");
				last;
			}
		}
	}
	return undef;
	} elsif($attr eq "authTimeout") {
	#Take over as is
	my $aDevice=AttrVal($hash->{NAME},"authDev",undef);
	if (!defined $aDevice && $init_done) {
		foreach my $dev ( sort keys %main::defs ) {
			if ($defs{$dev}->{TYPE} eq "GoogleAuth") {
				CommandAttr(undef,"$name authDev $dev");
				last;
			}
		}
	}
	return undef;
	} elsif($attr eq "authDev") {
	return undef unless (defined $val && $val ne "" && $init_done);
	my $bhash = $defs{$val};
	return "Not a GoogleAuth device $val" unless $bhash->{TYPE} eq "GoogleAuth";
	return undef;
	} elsif($attr eq "cmdKeyword") {
		return undef;
	} elsif($attr eq "babbleDev") {
		return undef unless (defined $val && $val ne "" && $init_done);
		my $bhash = $defs{$val};
		return "Not a Babble device $val" unless $bhash->{TYPE} eq "Babble";
		return undef;
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
		Signalbot_Init($own_hash,"");
	}
}

################################### 
sub Signalbot_Define($$) {			#
	my ($hash, $def) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}." Define: $def";
	
	$hash->{NOTIFYDEV} = "global";
		if ($init_done) {
			Log3 $hash->{NAME}, 5, "Define init_done: $def";
			my $ret=Signalbot_Init( $hash, $def );
			return $ret if $ret;
	}
	return undef;
}
################################### 
sub Signalbot_Init($$) {				#
	my ( $hash, $args ) = @_;
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Init: $args";
	if (defined $DBus_missing) {
		return "Please make sure that Net::DBus is installed, e.g. by 'sudo cpan install Net::DBus'";
	}
	my @a = ();
	@a = split("[ \t]+", $args) if defined $args;
	shift @a;shift @a;
	my $name = $hash->{NAME};
	if (defined $args && @a>0)	{
		return "Define: Wrong syntax. Usage:\n" .
		       "define <name> Signalbot";
	}

	Signalbot_Set($hash, $name, "setfromreading");
	my $ret = Signalbot_setup($hash);
	$hash->{STATE} = $ret if defined $ret;
	return $ret if defined $ret;
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
	$hash->{STATE}="Disconnected";
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
				Log3 $hash->{NAME}, 3, $hash->{NAME}.": parse cmd failed on ReplaceSetmagic with :$err: on  :$string:";
			} else {
				$msg = join(" ", @newargs);
				Log3 $hash->{NAME}, 5, $hash->{NAME}.": parse cmd returned :$msg:";
			}
			$msg = AnalyzeCommandChain( $hash, $msg );
			#If a normal FHEM command (no return value) is executed, $msg is undef - just the to empty string then
			if (!defined $msg) { 
				$msg=""; 
				Log3 $hash->{NAME}, 5, $hash->{NAME}.": commands executed without return value";
			}
			#Only way to distinguish a real error with the return stream
			if ($msg =~ /^Unknown command/) { 
				Log3 $hash->{NAME}, 3, $hash->{NAME}.": Error message: ".$msg;
				return ($msg, @processed); 
			}
			
			my ( $isMediaStream, $type ) = SignalBot_IdentifyStream( $hash, $msg ) if ( defined( $msg ) );
			if ($isMediaStream<0) {
				Log3 $hash->{NAME}, 5, $hash->{NAME}.": Media stream found $isMediaStream $type";
				my $tmpfilename="/tmp/signalbot".gettimeofday().".".$type;
				my $fh;
				#tempfile() would be the better way, but is not readable by signal-cli (how to set world-readable?)
				#could be changed with "chmod 0666, $tmpfilename;" which should even work on Windows, but what's the point - dbus/signal-cli works on Linux only anyways
				#my ($fh, $tmpfilename) = tempfile();
				if(!open($fh, ">", $tmpfilename,)) {
				#if (!defined $fh) {
					Log3 $hash->{NAME}, 3, $hash->{NAME}.": Can't write $tmpfilename";
					#return undef since this is a fatal error 
					return ("Can't write $tmpfilename",@processed);
				}
				print $fh $msg;
				close($fh);
				#If we created a file return the filename instead
				push @processed, $tmpfilename;
			} else {
				Log3 $hash->{NAME}, 5, $hash->{NAME}.": normal text found:$msg";
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
For German documentation see <a href="https://wiki.fhem.de/wiki/Signalbot">Wiki</a>
<ul>
	<a name="Signalbot"></a>
		provides an interface to the Signal Messenger, via signal_cli running as dbus daemon<br>
		The signal_cli package needs to be installed. See github for installation details on <a href="https://github.com/AsamK/signal-cli">signal-cli</a><br>
		An install script is available in the <a href="https://forum.fhem.de/index.php/topic,118370.0.html">FHEM forum</a><br>
		<br><br>
		Supported functionality (mainly due to limitations of the signal-cli dbus interface:<br>
		<ul>
		<li>Send messages to individuals and/or groups with or without attachments</li>
		<li>Work with contacts and groups using real names instead of internal codes and numbers</li>
		<li>Group and contact names can contain space - surround them with quotes to use them in set commands</li>
		<b>Limitations:</b><br>
		<li>The whole setup, registration and eving joining groups has to be done from signal-cli. The install shell script is however guiding through this process.</li>
		<li>Joining groups only via invitation link (not via invite!)</li>
		<br>
		</ul>
	<a name="Signalbot_Define"></a><br>
	<b>Define</b>
	<ul>
		<code>define &lt;name&gt; Signalbot</code><br>
		No arguments<br>
		<br>
	</ul>

	<a name="Signalbot_Set"></a>
	<b>Set</b>
	<ul>
		<li><b>set &lt;name&gt; &lt;send&gt; [@&lt;Recipient1&gt; ... @&lt;RecipientN&gt;] [#&lt;GroupId1&gt; ... #&lt;GroupIdN&gt;] [&&lt;Attachment1&gt; ... &&lt;AttachmentN&gt;] [&lt;Text&gt;]</b><br>
			<a name="send"></a>
			Send a message to a Signal recipient using @Name or @+49xxx as well as groups with #Group or #@Group along with an attachment with &<path to file> and a message.
		</li>
		<br>
		<li>
			<a name="send2"></a>
			<li>Use round brackets to let FHEM execute the content (e.g <code>&({plotAsPng('SVG_Temperatures')}</code></li>
			<li>If a recipient, group or attachment contains white spaces, the whole expression (including @ # or &) needs to be put in double quotes. Escape quotes within with \"</li>
			<li>If the round brackets contain curly brackets to execute Perl commands, two semi-colons (;;) need to be used to seperate multiple commands and at the end. The return value will be used e.g. as recipient</li>
			<li>For compatibility reasons @# can also be used to mark group names</li>
			<li>Messages to multiple recipients will be sent as one message</li>
			<li>Messages to multiple groups or mixed with individual recipients will be sent in multiple messages</li>
			<li>Attachments need to be file names readable for the fhem user with absolute path or relative to fhem user home</li>
			<li>Recipients can be either contact names or phone numbers (starting with +). Since signal-cli only understand phone numbers, 
			Signalbot tries to translate known contact names from its cache and might fail to send the message if unable to decode the contact<br>
			<li>To send multi line messages, use "\\n" in the message text</li>
			<br>
			Example:<br>
			<code>set Signalbot send "@({my $var=\"Joerg\";; return $var;;})" #FHEM "&( {plotAsPng('SVG_Temperatures')} )" Here come the current temperature plot</code><br>
			</ul>
			<br>
		</li>
		<li><b>set setContact &ltnumber&gt &ltname&gt</b><br>
		<a name="setContact"></a>
		Define a nickname for a phone number to be used with the send command and in readings<br>
		</li>
		<li><b>set createGroup &ltgroupname&gt [&&ltgroup picture&gt]</b><br>
		<a name="createGroup"></a>
		Define a new Signal group with the specified name.<br>
		Note: Pictures >2MB are known to cause issues and are blocked.<br>
		</li>
		<li><b>set updateGroup &ltgroupname&gt #[&ltnew groupname&gt] [&&ltgroup picture&gt]</b><br>
		<a name="updateGroup"></a>
		Update the name and/or group picture for an existing group.<br>
		Note: Pictures >2MB are known to cause issues and are blocked.<br>
		</li>
		<li><b>set invite &ltgroupname&gt &ltcontact&gt</b><br>
		<a name="invite"></a>
		Invite new members to an existing group.<br>
		</li>		
		<li><b>set block #&ltgroupname&gt|&ltcontact&gt</b><br>
		<a name="block"></a>
		Put a group or contact on the blocked list (at the server) so you won't receive messages anymore. While the attribute "allowedPeer" is handled on FHEM level and messages are still received (but ignored), FHEM will not receive messages anymore for blocked communication partners<br>
		</li>
		<li><b>set unblock #&ltgroupname&gt|&ltcontact&gt</b><br>
		<a name="unblock"></a>
		Reverses the effect of "block", re-enabling the communication.<br>
		</li>
		<a name="joinGroup"></a>
		<li><b>set joinGroup &ltgroup link&gt</b><br>
		Join a group via an invitation group like (starting with https://signal.group/....). This link can be sent from the group properties with the "group link" function.<br>
		Easiest way is to share via Signal and set the "autoJoin" attribute which be recognized by Signalbot to automatically join.<br>
		</li>
		<li><b>set quitGroup &ltgroup link&gt</b><br>
		<a name="quitGroup"></a>
		Quit from a joined group. This only sets the membership to inactive, but does not delete the group (see "get groups")"<br>
		</li>
		<li><b>set updateProfile &ltnew name&gt [&&ltavatar picture&gt]</b><br>
		<a name="updateProfile"></a>
		Set the name of the FHEM Signal user as well as an optional avatar picture.<br>
		</li>
		<li><b>set reinit</b><br>
		<a name="reinit"></a>
		Re-Initialize the module. For testing purposes when module stops receiving or has other issues. Should not be necessary.<br>
		</li>
		<br>
	</ul>
	
	<a name="Signalbot_Get"></a>
	<b>Get</b>
	<ul>
		<li><b>get contacts all|nonblocked</b><br>
			<a name="contacts"></a>
			Shows an overview of all known numbers and contacts along with their blocked status. If "nonblocked" is chosen the list will not containt blocked contacts.<br>
		</li>
		<li><b>get groups all|active|nonblocked</b><br>
			<a name="groups"></a>
			Shows an overview of all known groups along with their active and blocked status as well as the list of group members.<br>
			Using the "active" option, all non-active groups (those your quit) are hidden, with "nonblocked" additionally the blocked ones get hidden.<br>
		</li>
		<br>
	</ul>

	<a name="SignalbotAttr"></a>
	<b>Attributes</b>
	<ul>
		<br>
		<li><b>authTimeout</b><br>
		<a name="authTimeout"></a>
			The number of seconds after which a user authentificated for command access stays authentifcated.<br>
			Default: -, valid values: decimal number<br>
		</li>
		<li><b>authDev</b><br>
		<a name="authDev"></a>
			Name of GoogleAuth device. Will normally be automatically filled when setting an authTimeout if a GoogleAuth device is already existing.<br>
		</li>
		<li><b>autoJoin 0|1</b><br>
		<a name="authJoin"></a>
			If set to 1, Signalbot will automatically inspect incoming messages for group invite links and join that group.<br>
			Default: 0, valid values: 0|1<br>
		</li>
		<li><b>allowedPeer</b><br>
		<a name="allowedPeer"></a>
			Comma separated list of recipient(s) and/or groupId(s), allowed to
			update the msg.* readings and trigger new events when receiving a new message.<br>
			<b>If the attribute is not defined, everyone is able to trigger new events!!</b>
		</li>
		<li><b>babblePeer</b><br>
		<a name="babblePeer"></a>
			Comma separated list of recipient(s) and/or groupId(s) that will trigger that messages are forwarded to a Babble module defined by "BabbleDev". This can be used to interpret real language interpretation of messages as a chatbot or to trigger FHEM events.<br>
			<b>If the attribute is not defined, nothing is sent to Babble</b>
		</li>
		<li><b>babbleDev</b><br>
		<a name="babbleDev"></a>
			Name of Babble Device to be used. This will typically be automatically filled when bubblePeer is set.<br>
			<b>If the attribute is not defined, nothing is sent to Babble</b>
		</li>
		<li><b>commandKeyword</b><br>
		<a name="commandKeyword"></a>
			One or more characters that mark a message as GoogleAuth protected command which is directly forwarded to FHEM for processing. Example: for "="<br>
			=123456 set lamp off<br>
			where "123456" is a GoogleAuth token. The command after the token is optional. After the authentification the user stay for "authTimeout" seconds authentificated and can execute command without token (e.g. "=set lamp on").<br>
			<b>If the attribute is not defined, no commands can be issued</b>
		</li>
		<br>
	</ul>
	<br>
	<a name="SignalbotReadings"></a>
	<b>Readings</b>
	<ul>
		<br>
		<li><b>(prev)msgAttachment</b></li>
		Attachment(s) of the last received (or for history reasons the previous before). The path points to the storage in signal-cli and can be used to retrieve the attachment.<br>
		<li><b>(prev)msgGroupName</b></li>
		Group of the last message (or for history reasons the previous before). Empty if last message was a private message<br>
		<li>(prev)msgSender</b></li>
		Sender that sent the last message (or previous before) <br>
		<li><b>(prev)msgText</b></li>
		Content of the last message <br>
		<li><b>(prev)msgTimestamp</b></li>
		Time the last message was sent (a bit redundant, since all readings have a timestamp anyway<br>
		<li><b>msgAuth</b></li>
		Set to 1 if the user was authentificated via GoogleAuth by the time the message arrived, 0 otherwise.<br>
		<li><b>sentMsg</b></li>
		Content of the last message that was sent from this module<br>
		<li><b>sentRecipient</b></li>
		Recipient of the last message that was sent<br>
		This is taken from the actual reply and will contain the last recipient that confirmed getting the message in case multiple recipients or group members got it<br>
		<li><b>sentMsgTimestamp</b></li>
		Timestamp the message was received by the recipient. Will show pending of not confirmed (likely only if even the Signal server did not get it)<br>
		<li><b>joinedGroups</b></li>
		Comma separated list of groups the registered number has joined. Inactive groups will be skipped, blocked groups appear in brackets.<br>
	<br>
</ul>

=end html

=cut
