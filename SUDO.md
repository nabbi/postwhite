# non-root

Postwhite can be ran without root, leveraging sudo for postfix reloads


## setup

Create service account

```shell
groupadd postwhite
useradd -g postwhite
```

update postfixpath in postwhite.conf to reflect this new path

```shell
mkdir /etc/postwhite
chgrp postwhite /etc/postwhite
chmod g+w /etc/postwhite
```

If you are using the non-spf yahoo list, then you'll also need to adjust the group permissions on that file or move yahoo_static_hosts into this new dir.


visudo

```text
postwhite ALL=(ALL) NOPASSWD: /usr/sbin/postfix reload
```
