# Seed delivery

The installer ISO is booted **unchanged**. The seed is a separate small image (or HTTP directory) that supplies
`user-data` and `meta-data` as a cloud-init **NoCloud** datasource.

> A seed contains credentials and drives an installer that erases disks. Keep it private, deliver it only to the
> machine it was built for, and delete it afterwards.

## Formats

| Format | File | Use |
| --- | --- | --- |
| `iso` | `nocloud-seed.iso` | second USB, extra Ventoy partition, VM CD-ROM |
| `img` | `nocloud-seed.img` (4 MiB VFAT) | general USB seed |
| `floppy` | `nocloud-seed-floppy.img` (1.44 MB FAT12) | BMC virtual-floppy upload (limit 1,474,560 bytes) |

All carry the volume label `CIDATA` and exactly two files, `user-data` and `meta-data`. `meta-data` must contain an
`instance-id` (an empty file is not valid for NoCloud).

## Boot parameters

At the installer's GRUB menu press `e` and append to the `linux` line:

```text
autoinstall ds=nocloud
```

`autoinstall` is required: without it the installer asks for confirmation before erasing disks. A semicolon typed at the
GRUB prompt ends the command, so a form such as `ds=nocloud;s=...` must have the semicolon escaped (`\;`) or the option
quoted. Plain `ds=nocloud` finds an attached volume labelled `CIDATA`.

## HTTP delivery

Serve a directory holding the **rendered** `user-data` and `meta-data` (the output of `render`, not the template) and
point the installer at it:

```text
autoinstall ds=nocloud-net;s=http://<server>:<port>/
```

The same escaping rule applies to the semicolon. Everything in that directory is credential-bearing: bind the server to
one address, serve only that directory, and stop it as soon as the installer has fetched the files.

## BMC virtual floppy

Upload `nocloud-seed-floppy.img` through the BMC's virtual media (floppy slot) and leave it mounted for the whole install.
The BMC presents it to the host as a USB device labelled `CIDATA`. Labels and limits vary by firmware: confirm yours.

## After the install

Delete the seed (`img`/`iso`/`floppy` files, any served directory). The installed system keeps its own copy of the
rendered user-data in installer logs; whether those logs retain secrets is checked in the VM test matrix
([verification.md](verification.md)).
