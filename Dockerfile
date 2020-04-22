FROM freeradius/freeradius-server:latest

# Author of this Dockerfile
MAINTAINER Cuediin <cuediin@yahoo.co.uk>

ENV PATH="/scripts:${PATH}"

ARG SYSLOG_IP=not_defined
ARG SYSLOG_PORT=514
ARG clients="home:192.168.0.0/23:testing123"
ARG users="user1:password,user2:passwrd"
# Update & upgrades
RUN apt-get update -y && apt-get upgrade -y

RUN apt-get install rsyslog -y && \
    mkdir /scripts && \
    sed -i -e "s/^module(load=\"imklog\"/\#module(load=\"imklog\"/g" -e "s/^\#module(load=\"imtcp\")/module(load=\"imtcp\")/g" -e "s/^\#input(type=\"imtcp\"/input(type=\"imtcp\"/g"  /etc/rsyslog.conf && \
    sed -i -e "s/^logdir.*$/logdir = syslog/g" -e "s/^\s*destination.*$/destination = syslog/g" /etc/freeradius/radiusd.conf && \
    sed -i -e "\$adaemon\.\*  \/var\/log\/auth.log" /etc/rsyslog.d/50-default.conf && \
    if [ "xx${SYSLOG_IP}xx" != "xxnot_definedxx" ]; then \
      echo "#" > /etc/rsyslog.d/99_remote_syslog.conf; \
      sed -i -e "\$a\*\.\*  \@\@${SYSLOG_IP}\:${SYSLOG_PORT}" /etc/rsyslog.d/99_remote_syslog.conf; \ 
    fi

# Backup files the script modifies depending on installation type
RUN  \
    mkdir /var/log/freeradius/radacct && \
    cp /etc/freeradius/radiusd.conf /etc/freeradius/radiusd.conf.orig && \
    cp /etc/freeradius/clients.conf /etc/freeradius/clients.conf.orig && \
    cp /etc/freeradius/sites-available/default /etc/freeradius/sites-available/default.orig && \
    cp /etc/freeradius/mods-config/files/authorize /etc/freeradius/mods-config/files/authorize.orig && \
    cp /etc/pam.d/radiusd /etc/pam.d/radiusd.orig && \
    mkdir /etc/freeradius/totp && \
    echo "#" > /etc/freeradius/users-cleartext.txt && \
    echo "#" > /etc/freeradius/users-totp.txt && \
    echo "#" > /scripts/totp_mgmt.sh && \
    chmod 700 /scripts/totp_mgmt.sh && \
    echo "#" > /scripts/user_mgmt.sh && \
    chmod 700 /scripts/user_mgmt.sh

# SERVER_TYPE TOTP_ONLY CLEAR_ONLY BOTH
ARG server_type="BOTH"

# Install FreeRADIUS and Google Authenticator
RUN apt-get install qrencode libpam-google-authenticator -y && ln -s /etc/freeradius/mods-available/pam /etc/freeradius/mods-enabled/pam

# Edit /etc/freeradius/users file to include the two new user files for PAM users and ClearText users
RUN sed -i -e "1s/^/#Instruct FreeRADIUS to use include files. users-cleartext containts username and password, users-totp.txt containts username and auth-type:= PAM.\n#\$include \/etc\/freeradius\/users-cleartext.txt\n#\$include \/etc\/freeradius\/users-totp.txt\n/g" /etc/freeradius/mods-config/files/authorize
# Edit /etc/freeradius/users file to default authentication to PAM, but commented out
RUN sed -i -e "1s/^/#Default RADIUS to use PAM authentication, only appropriate if running TOTP ONLY.\n#DEFAULT Auth-Type := PAM\n/" /etc/freeradius/mods-config/files/authorize

# Ensure authentication requests are logged to the log file
RUN sed -i -e "s/auth\s=\sno/auth = yes/g" /etc/freeradius/radiusd.conf

# Edit /etc/pam.d/radiusd file to point to the folder and User's secret file
RUN sed -i -e 's/@include/#@include/g' -e "\$aauth required pam_google_authenticator.so secret=/etc/freeradius/totp/\${USER}.google.secret user=root\n" /etc/pam.d/radiusd

# Update PAM files
RUN sed -i -e "s/^account\srequisite/#account requisite/g" /etc/pam.d/common-account

# Update user to root user. this helps fix some dependencies when using the PAM modules
RUN sed  -i -e "s/freerad$/root/g" /etc/freeradius/radiusd.conf

# Update to use PAM
RUN sed -i -e "s/#\spam/pam/g" /etc/freeradius/sites-available/default

RUN sed -i -e "1s/^#/#\!\/bin\/bash\n# Bash script for basic TOTP management\n\ncase \"\$1\" in\n  set)\n    if [ \"\$#\" -ne 3 ]; then\n      echo \"Illegal number of parameters\"\n      exit 2\n    fi\n    case \"\$2\" in\n      HOSTNAME|EMERGENCY_CODES|RATE_LIMIT|RATE_TIME|SERVER_TYPE)\n      if [ \"\$2\" == \"SERVER_TYPE\" ] \&\& [ \"\$3\" \!= \"BOTH\" ] \&\& [ \"\$3\" \!= \"TOTP_ONLY\" ] \&\& [ \"\$3\" \!= \"CLEAR_ONLY\" ]; then\n        echo \"SERVER_TYPE acceptable values: BOTH TOTP_ONLY CLEAR_ONLY.\"\n        echo \"Be aware of the case being used.\"\n      else\n        sed -i -e \"s\/\$2=.*\/\$2=\$3\/g\" \/scripts\/user_mgmt.sh\n      fi\n      ;;\n\n      *)\n        echo \"Usage: \$0 set HOSTNAME|EMERGENCY_CODES|RATE_LIMIT|RATE_TIME VALUE\"\n        exit 1\n        ;;\n      esac\n    ;;\n\n\n  add)\n    case \"\$2\" in\n      client)\n        if [ \"\$#\" -ne 5  ]; then\n          echo \"Illegal number of parameters. totp_mgmt.sh add client [client_name] [client_IP_CIDR] [client_secret]\"\n          exit 2\n        fi\n        if grep -qw \${3} \/etc\/freeradius\/clients.conf; then\n          echo Client \${3} already exists.\n          exit 2\n        fi\n        if grep -qw \${4} \/etc\/freeradius\/clients.conf; then\n          echo Subnet \${4} already exists.\n          exit 2\n        fi\n        sed -i -e \"\\\\\$a client \$3 {\\\n    ipaddr = \$4\\\n    secret = \$5\\\n}\\\n\\\n\" \/etc\/freeradius\/clients.conf\n        echo \"Client added, please remember to restart the container.\"\n      ;;\n\n      *)\n        echo \"Usage: \$0 add client\"\n        exit 1\n        ;;\n      esac\n    ;;\n\n  rm)\n    case \"\$2\" in\n      client)\n        if [ \"\$#\" -ne 3  ]; then\n          echo \"Illegal number of parameters. totp_mgmt.sh rm client [client_name]\"\n          exit 2\n        fi\n        if grep -qw \${3} \/etc\/freeradius\/clients.conf; then\n          sed -i -e \"\/^client \$3\/,+4d\" \/etc\/freeradius\/clients.conf\n           echo \"Client removed, please remember to restart the container.\"\n          else\n          echo \"Client \${3} does not exist.\"\n          exit 2\n        fi\n      ;;\n\n      *)\n        echo \"Usage: \$0 rm client\"\n        exit 1\n        ;;\n      esac\n    ;;\n\n \n  view)\n    case \"\$2\" in\n      clients)\n        grep -w ^client \/etc\/freeradius\/clients.conf | awk '{print \$2;}'\n      ;;\n\n      client)\n        if [ \"\$#\" -ne 3  ]; then\n          echo \"Illegal number of parameters. totp_mgmt.sh view client [client_name]\"\n          exit 2\n        fi\n        if grep -qw \${3} \/etc\/freeradius\/clients.conf; then\n          sed -n \"\/^client \$3\/,+3p\" \/etc\/freeradius\/clients.conf\n               else\n          echo Client \${3} does not exist.\n        fi\n      ;;\n\n      config)\n        for each in SERVER_TYPE HOSTNAME EMERGENCY_CODES RATE_LIMIT RATE_TIME; do grep ^\${each} \/scripts\/user_mgmt.sh | sed \"s\/=\/ \/g\"; done\n      ;;\n\n      *)\n        echo \"Usage: \$0 view clients|totp_config|client <client name>\"\n        exit 1\n        ;;\n      esac\n    ;;\n\n  *)\n    echo \"Usage: \$0 set|view|add\"\n    exit 1\n    ;;\nesac\n\nexit \$ret\n/" /scripts/totp_mgmt.sh

RUN sed -i -e "1s/^#/#\!\/bin\/bash\n# Bash script for basic user management\nUSERNAME=\`echo \$2 | awk -F: '{print tolower(\$1);}'\`\nPASSWORD=\`echo \$2 | awk -F: '{print \$2;}'\`\nSERVER_TYPE=BOTH\nTOTP_LOCATION=\/etc\/freeradius\/totp\nHOSTNAME=home-auth\nEMERGENCY_CODES=2\nRATE_LIMIT=3\nRATE_TIME=60\n\n\ncase \"\$1\" in\n  add)\n    if [ \"\$#\" -ne 2 ]; then\n      echo \"Illegal number of parameters\"\n      exit 2\n    fi\n    if [ -f \${TOTP_LOCATION}\/\${USERNAME}.google.secret ]; then\n      echo \${USERNAME} secret file already exists, please use remove then add \/ import.\n      exit 2\n    else\n      if grep -qw \${USERNAME} \/etc\/freeradius\/users-cleartext.txt; then\n        echo \${USERNAME} already exists as a Cleartext user, please remove and add again, or update.\n        exit 2\n      fi\n    fi\n    if [[ \$2 == *\":\"* ]]; then\n      # username and password included in the string assuming cleartext username\n      if [ \"\${SEVER_TYPE}\" \!= \"TOTP_ONLY\" ]; then\n        echo \${USERNAME} Cleartext-password := \${PASSWORD} >> \/etc\/freeradius\/users-cleartext.txt\n        logger Cleartext user \${USERNAME} created.\n        echo \"\${USERNAME} created as a Cleartext user. Please restart this docker container.\"\n      else\n        echo \"Username:Password Cleartext user format detected in a TOTP only configuration\"\n        exit 2         \n      fi\n    else\n      # username only in the string, assuming TOTP username\n      if [ \"\${SEVER_TYPE}\" \!= \"CLEAR_ONLY\" ]; then\n        google-authenticator --time-based --disallow-reuse --force --emergency-codes=\${EMERGENCY_CODES} --rate-limit=\${RATE_LIMIT} --rate-time=\${RATE_TIME} --minimal-window --label=\${USERNAME} --issuer=\${HOSTNAME} --secret=\${TOTP_LOCATION}\/\${USERNAME}.google.secret\n        echo \${USERNAME} Auth-Type := PAM >> \/etc\/freeradius\/users-totp.txt\n        logger TOTP user \${USERNAME} created.               echo \"TOTP user created. Please scan this qrcode with your authenticator, or communicate the manual code to the user.\"\n        echo \"Please restart this docker container.\"\n     else\n       echo \"Username only format (assuing TOTP user) detected in a Cleartext only configuration\"\n       exit 2      \n     fi\n   fi\n   ;;\n\n  update)\n    if [ \"\$#\" -ne 2 ]; then\n      echo \"Illegal number of parameters\"\n      exit 2\n    fi\n    if [ -f \${TOTP_LOCATION}\/\${USERNAME}.google.secret ]; then\n      echo \"Not possible to update a TOTP user. Use remove then add or import.\"\n    else\n      if grep -qw \${USERNAME} \/etc\/freeradius\/users-cleartext.txt; then\n        if [[ \$2 == *\":\"* ]]; then\n          # username and password included in the string assuming cleartext username\n          sed -i -e \"s\/^\${USERNAME} .*\/\${USERNAME} Cleartext-password := \${PASSWORD}\/\" \/etc\/freeradius\/users-cleartext.txt\n          logger Cleartext user \${USERNAME} password updated.\n          echo \"Cleartext password updated for \${USERNAME}. Please restart this docker container.\"\n        else\n          echo \"Incorrect Username:Password format, please ensure single arguemet with Username:Password is used.\"\n              exit 2         \n        fi\n      else\n        echo \"No user exists by that name.\"\n      fi\n    fi\n   ;;\n\n  remove)\n    if [ \"\$#\" -ne 2 ]; then\n      echo \"Illegal number of parameters\"\n      exit 2\n    fi\n    if [ -f \${TOTP_LOCATION}\/\${USERNAME}.google.secret ]; then\n      rm \${TOTP_LOCATION}\/\${USERNAME}.google.secret\n          logger TOTP user \${USERNAME} removed.       echo \${USERNAME} google authenticator secret file deleted.\n     else\n    if grep -qw \${USERNAME} \/etc\/freeradius\/users-cleartext.txt; then\n        sed -i -e \"\/^\${USERNAME} \/d\" \/etc\/freeradius\/users-cleartext.txt\n      if grep -qw \${USERNAME} \/etc\/freeradius\/users-cleartext.txt; then\n               echo \"Cleartext user not removed.\";\n            else\n          logger Cleartext user \${USERNAME} removed.            echo Cleartext user \${USERNAME} removed.;\n           fi\n      else\n            echo \"No user exists by that name.\"\n       fi\n  fi\n    ;;\n\n  view)\n    if [ \"\$#\" -ne 2 ]; then\n      echo \"Illegal number of parameters\"\n      exit 2\n    fi\n    if [ -f \${TOTP_LOCATION}\/\${USERNAME}.google.secret ]; then\n      SECRET=\`head -1 \${TOTP_LOCATION}\/\${USERNAME}.google.secret\`\n      qrencode -o- -d 300 -s 5 -t ANSI \"otpauth:\/\/totp\/\${USERNAME}?secret=\${SECRET}\&issuer=\${HOSTNAME}\"\n      cat \${TOTP_LOCATION}\/\${USERNAME}.google.secret\n     else\n    if grep -qw \${USERNAME} \/etc\/freeradius\/users-cleartext.txt; then\n        grep -w \${USERNAME} \/etc\/freeradius\/users-cleartext.txt\n        exit 2\n         else\n            echo \"No user exists by that name.\"\n       fi\n    fi\n    ;;\n\n  list)\n    echo \"TOTP Users:\"\n    ls \${TOTP_LOCATION} | sed -e \"s\/.google.secret\/\/g\"\n    echo #\n        echo \"Cleartext Users:\"\n     awk '{ if (NF>2) print \$1;}' \/etc\/freeradius\/users-cleartext.txt\n    ;;\n\n  import)\n    if [ \"\$#\" -ne 2 ]; then\n      echo \"Illegal number of parameters\"\n      exit 2\n    fi\n       if [ \"\${SEVER_TYPE}\" == \"CLEAR_ONLY\" ]; then\n      echo \"Trying to import a TOTP user in a Cleartext only configuration. Operation failed.\"\n      exit 2\n    fi\n   echo \"Please paste in the file you wish to import. Use Ctrl+D to terminate input.\"\n    while read line\n      do\n        echo \"\$line\" >> \${TOTP_LOCATION}\/\${USERNAME}.google.secret\n      done < \"\/dev\/stdin\"\n    echo \${USERNAME} Auth-Type := PAM >> \/etc\/freeradius\/users-totp.txt\n    chmod 400 \${TOTP_LOCATION}\/\${USERNAME}.google.secret\n    logger Cleartext user \${USERNAME} imported.            \n       echo Cleartext user \${USERNAME} imported.    \n        ;;\n\n  *)\n    echo \"Usage: \$0 add|update|remove|view|import|list\"\n    exit 1\n    ;;\nesac\n\nexit \$ret\n\n\n/" /scripts/user_mgmt.sh

RUN if [ "${server_type}" = "TOTP_ONLY" ] ; then sed -i -e "2s/^#DEFAULT/DEFAULT/g" /etc/freeradius/mods-config/files/authorize; else sed -i -e "s/^#\$include/\$include/g" /etc/freeradius/mods-config/files/authorize; fi

RUN echo ${users} | sed -e "s/,/\n/g" | awk -F: '{ print $1" Cleartext-password := "$2"\n";}' > /etc/freeradius/users-cleartext.txt

RUN echo ${clients} | sed -e "s/,/\n/g" | awk -F: '{ print "client "$1" {\n    ipaddr = "$2"\n    secret = "$3"\n}\n";}' >> /etc/freeradius/clients.conf

#Update Debug code here to install VIM
ARG debug="xxx"
RUN if [ "${debug}" = "1" ] ; then apt-get install vim -y; fi

RUN echo "#" > /sbin/entrypoint.sh
RUN chmod 700 /sbin/entrypoint.sh
RUN sed -i -e "s/^#/#!\/bin\/bash\n# Bash script for starting rsyslog and FreeRADIUS container\nrsyslogd\nfreeradius -f\n/" /sbin/entrypoint.sh
ENTRYPOINT ["/sbin/entrypoint.sh", ""]
