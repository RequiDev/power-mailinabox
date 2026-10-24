#!/bin/bash
#
# Dovecot (IMAP/POP and LDA)
# ----------------------
#
# Dovecot is *both* the IMAP/POP server (the protocol that email applications
# use to query a mailbox) as well as the local delivery agent (LDA),
# meaning it is responsible for writing emails to mailbox storage on disk.
# You could imagine why these things would be bundled together.
#
# As part of local mail delivery, Dovecot executes actions on incoming
# mail as defined in a "sieve" script.
#
# Dovecot's LDA role comes after spam filtering. Postfix hands mail off
# to Spamassassin which in turn hands it off to Dovecot. This all happens
# using the LMTP protocol.

source setup/functions.sh # load our functions
source /etc/mailinabox.conf # load global vars


# Install packages for dovecot. These are all core dovecot plugins.

echo "Installing Dovecot (IMAP server)..."
apt_install \
	dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-sqlite sqlite3 \
	dovecot-sieve dovecot-managesieved

# The `dovecot-imapd`, `dovecot-pop3d`, `dovecot-lmtpd` and `dovecot-managesieved`
# packages enable their protocols through /usr/share/dovecot/protocols.d.

# Dovecot 2.4 does not understand the 2.3 configuration syntax, and Debian's
# conf.d files are mostly empty skeletons whose defaults (mbox, system users)
# don't apply to us. So we own the whole configuration: dovecot.conf includes
# only the protocols and the files we write to /etc/dovecot/mailinabox.d.
# Anything placed in /etc/dovecot/local.conf is still loaded last.
mkdir -p /etc/dovecot/mailinabox.d
rm -f /etc/dovecot/conf.d/99-local*.conf /etc/dovecot/conf.d/auth-sql.conf.ext /etc/dovecot/dovecot-sql.conf.ext # 2.3 leftovers #NODOC
cat > /etc/dovecot/dovecot.conf << EOF;
# Written by Mail-in-a-Box. Do not edit; changes are lost on the next setup run.
dovecot_config_version = 2.4.0
dovecot_storage_version = 2.4.0

!include_try /usr/share/dovecot/protocols.d/*.protocol
!include mailinabox.d/*.conf
!include_try local.conf
EOF

# The inotify `max_user_instances` default is 128, which constrains
# the total number of watched (IMAP IDLE push) folders by open connections.
# See http://www.dovecot.org/pipermail/dovecot/2013-March/088834.html.
# A reboot is required for this to take effect (which we don't do as
# as a part of setup). Test with `cat /proc/sys/fs/inotify/max_user_instances`.
management/editconf.py /etc/sysctl.conf \
	fs.inotify.max_user_instances=1024

# Notes on the settings below:
#
# * `default_process_limit` is 100 by default, which constrains the total number
#   of active IMAP connections (at, say, 5 open connections per user that would be
#   20 users). Set it to 250 times the number of cores this machine has. The auth
#   and anvil services serve every login process at once (five services), so
#   their client limits are raised to match.
# * `default_vsz_limit` is the maximum amount of virtual memory that can be
#   allocated. Set it to 1/3 of the total available memory (physical mem + swap).
# * Mailboxes are stored in Maildir++ format at mailboxes/domain/user. The home
#   directory is the maildir itself, as it has always been on Mail-in-a-Box.
#   We'll ensure that no bad domains or email addresses are created within the
#   management daemon.
# * Passwords may only be sent over TLS, and only the over-TLS versions of IMAP
#   and POP (ports 993 and 995) are made available. The LOGIN mechanism is for
#   Microsoft products like Outlook.
# * TLS follows Mozilla's "Intermediate" recommendations.
# * IMAP IDLE "still here" notifications are sent every 4 minutes instead of 2
#   to save bandwidth and battery on mobile devices (#129).
# * The POP3 UIDL format is pinned to the uppercase hex of Dovecot 2.3 so that
#   POP3 clients don't download every message again.
# * LMTP listens on port 10026 for mail that has passed through spampd.
#   Setting a `postmaster_address` is required or LMTP won't start. An alias
#   will be created automatically by our management daemon.
# * Quotas are tracked in the mail indexes (the `count` driver). The per-user
#   limit comes from the user database (see mail-users.sh). The quota-status
#   service lets Postfix reject mail for full mailboxes before accepting it.
# * Sieve: our global script moves mail marked as spam into the Spam folder. It
#   runs before the global_before scripts, the user's own scripts (managed with
#   ManageSieve, stored outside the maildir so they don't appear as folders),
#   and the global_after scripts.
process_limit=$(( $(nproc) * 250 ))
cat > /etc/dovecot/mailinabox.d/10-mail.conf << EOF;
# Written by Mail-in-a-Box. Do not edit; changes are lost on the next setup run.
log_path = /var/log/mail.log
default_process_limit = $process_limit
default_vsz_limit = $(echo "$(free -tm  | tail -1 | awk '{print $2}') / 3" | bc)M
service auth {
  client_limit = $(( process_limit * 5 ))
}
service anvil {
  client_limit = $(( process_limit * 5 ))
}

mail_driver = maildir
mail_home = $STORAGE_ROOT/mail/mailboxes/%{user | domain}/%{user | username}
mail_path = %{home}
mail_uid = mail
mail_gid = mail
mail_privileged_group = mail
first_valid_uid = 0
mail_plugins {
  quota = yes
}

auth_allow_cleartext = no
auth_mechanisms = plain login

ssl = required
ssl_server_cert_file = $STORAGE_ROOT/ssl/ssl_certificate.pem
ssl_server_key_file = $STORAGE_ROOT/ssl/ssl_private_key.pem
ssl_server_dh_file = $STORAGE_ROOT/ssl/dh2048.pem
ssl_min_protocol = TLSv1.2
ssl_cipher_list = ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
ssl_server_prefer_ciphers = client

service imap-login {
  inet_listener imap {
    port = 0
  }
}
service pop3-login {
  inet_listener pop3 {
    port = 0
  }
}

protocol imap {
  imap_idle_notify_interval = 4 mins
  mail_max_userip_connections = 40
  mail_plugins {
    imap_quota = yes
  }
}

protocol pop3 {
  pop3_uidl_format = %{uid | hex(8) | upper}%{uidvalidity | hex(8) | upper}
}

service lmtp {
  inet_listener lmtp {
    listen = 127.0.0.1
    port = 10026
  }
}
postmaster_address = postmaster@$PRIMARY_HOSTNAME
protocol lmtp {
  mail_plugins {
    sieve = yes
  }
}

quota "User quota" {
  driver = count
}
protocol !indexer-worker {
  mail_vsize_bg_after_count = 100
}
quota_status_success = DUNNO
quota_status_nouser = DUNNO
quota_status_overquota = "522 5.2.2 Mailbox is full"
service quota-status {
  executable = quota-status -p postfix
  inet_listener quota-status {
    listen = 127.0.0.1
    port = 12340
  }
  client_limit = 1
}

sieve_script spam {
  type = before
  path = /etc/dovecot/sieve-spam.sieve
}
sieve_script global_before {
  type = before
  path = $STORAGE_ROOT/mail/sieve/global_before
}
sieve_script personal {
  path = $STORAGE_ROOT/mail/sieve/%{user | domain}/%{user | username}
  active_path = $STORAGE_ROOT/mail/sieve/%{user | domain}/%{user | username}.sieve
}
sieve_script global_after {
  type = after
  path = $STORAGE_ROOT/mail/sieve/global_after
}
sieve_redirect_envelope_from = recipient
sieve_vacation_send_from_recipient = yes
EOF

# Create, subscribe, and mark as special folders: INBOX, Drafts, Sent, Trash, Spam and Archive.
cp conf/dovecot/15-mailboxes.conf /etc/dovecot/mailinabox.d/

# Copy the global sieve script into where we've told Dovecot to look for it. Then
# compile it. Global scripts must be compiled now because Dovecot won't have
# permission later.
cp conf/sieve-spam.txt /etc/dovecot/sieve-spam.sieve
sievec /etc/dovecot/sieve-spam.sieve

# PERMISSIONS

# Ensure configuration files are owned by dovecot and not world readable.
chown -R mail:dovecot /etc/dovecot
chmod -R o-rwx /etc/dovecot

# Ensure mailbox files have a directory that exists and are owned by the mail user.
mkdir -p $STORAGE_ROOT/mail/mailboxes
chown -R mail:mail $STORAGE_ROOT/mail/mailboxes

# Same for the sieve scripts.
mkdir -p $STORAGE_ROOT/mail/sieve
mkdir -p $STORAGE_ROOT/mail/sieve/global_before
mkdir -p $STORAGE_ROOT/mail/sieve/global_after
chown -R mail:mail $STORAGE_ROOT/mail/sieve

# Allow the IMAP/POP ports in the firewall.
ufw_allow imaps
ufw_allow pop3s

# Allow the Sieve port in the firewall.
ufw_allow sieve

# Restart services.
restart_service dovecot
