#! /usr/bin/env perl
#
# dosmc: C compiler and assembler to produce tiny DOS .exe and .com executables
# by pts@fazekas.hu at Thu Jun 25 00:59:56 CEST 2020
#
# TODOs:
#
# !! Optimize away call in entry point of main and _start. This can be tricky and needs smart disassembly, for example in examples/m0f.c, code of _start and double_int overlap.
# !! Optimize away extra exit after _start.
# !! Optimize away `pop ...' registers at end of _start.
# !! Optimize `mov al, ...; mov ah, ...' at end of main and _start.
# !! Add option for word alignment of data segments, for speed.
# !! TODO(pts): Add automatic argv splitting for main, but keep using argc=0 and argv=NULL if -D_STUBARG_MAIN, and keep these unspecified if -D_NOARG_MAIN.
# !! Add disassembler to check that ds is not used in the .exe file, and optimize away `pop ds'. (Without a disassembler, even if _CONST, _CONST2 and _DATA are empty, pointers to local (on-stack) variables may be taken and they won't work.)
# !! Optimize away everything if the first instruction by the entry point is `ret' or exit.
# !! Optimize away unused basic blocks from .text.
# !! Remove `push dx' and `pop dx' (and other register operations) from examples/hello.com.
# !! Make simple_nasm_exe.nasm work with the built-in linker (ds, ss, sp setup is unnecessary, remove that).
# !! Add -bt=auto for using .com if it fits to 64 KiB of memory, otherwise using .exe. Also autodetect .bin for a single .nasm source file with non-0x100 org in the beginning.
# !! Patch `END' to `END ...' in the -cw output. This is hard (needs .obj file modification to add an LPUBDEF) if there is no label for that already.
# !! Add -cm to produce .nasm (from .obj, using db for instructions) which can be used next time to produce an identical executable. This is similar to -cn, but will need `nasm -f obj' and doesn't link .obj files together.
# !! Cleanup flag to remove .tmp files.
# !! doc: http://nuclear.mutantstargoat.com/articles/retrocoding/dos01-setup/
# !! Add instructions to build with wcl and debug info (produces larger .exe), and to use debugger.
# !! For the Win32 port: port dosmc.dir/preamblew.pm to Win32, or remove packages which don't work.
# !! Win32 port: Remove \r (fixing line breaks) from wdis output, to make it compatible with Linux.
#

BEGIN { $^W = 1 }
use integer;
use strict;

my $is_win32 = $^O =~ m@win32\b@i;  # Example: "MSWin32", "linux".
my $path_sep = $is_win32 ? ";" : ":";
my $tool_exe_ext = $is_win32 ? ".exe" : "";
my $MYDIR = $0;
if ($is_win32) {
  # TODO(pts): Simplify $0 based on current directory, now it's absolute.
  die "$0: fatal: script directory not specified\n" if $MYDIR !~ s@[/\\]+[^/\\]+\Z(?!\n)@@;
  die "$0: fatal: bad current directory: $MYDIR\n" if $MYDIR =~ m@"@;  # For $ENV{PATH}.
} else {
  die "$0: fatal: script directory not specified\n" if $MYDIR !~ s@/+[^/]+\Z(?!\n)@@;
  die "$0: fatal: bad current directory: $MYDIR\n" if $MYDIR =~ m@:@;  # $ENV{PATH} separator.
}
$0 = $ENV{__SCRIPTFN} if defined($ENV{__SCRIPTFN});

if (!@ARGV or $ARGV[0] eq "-?" or $ARGV[0] eq "-h" or $ARGV[0] eq "--help" or $ARGV[0] eq "help") {
  die "$0: fatal: cannot redirect stdout\n" if !@ARGV and !open(STDOUT, ">&", \*STDERR);
  print "dosmc: C compiler and assembler to produce tiny DOS .exe and .com executables\n";
  print "This is free software, GNU GPL >=2.0. There is NO WARRANTY. Use at your risk.\n";
  print "Usage: $0 [<compiler-flag> ...] <source-file> [...]\n";
  print "Usage: $0 <perl-script> [...]\n";
  print "Usage: $0 <directory> [...]  # Build with dosmcdir.pl\n";
  print "To compile DOS .exe, specify no flag. To compile DOS .com, specify -bt=com\n";
  print "Supported <source-file> types: .c, .nasm, .wasm, .asm, .obj, .lib\n";
  print "See details on https://github.com/pts/dosmc\n";
  exit(@ARGV ? 0 : 1);
}

# --- Linker: Reads .obj files, writes .exe and .com files (for equivalent .nasm files).

# Checks if the entry point contains an instructions to exit immediately,
# return exit code (0..255) if found, otherwise returns undef.
sub get_8086_exit_code($$) {
  my($data, $text_symbol_ofsr) = @_;
  pos($data) = defined($text_symbol_ofsr->{_start_}) ? $text_symbol_ofsr->{_start_} : $text_symbol_ofsr->{main_};
  return 0 if $data =~ /\G(?:\x31\xC0)?\xC3/gcs;  # xor ax, ax;; ret
  $data =~ /\G[\x06\x0E\x16\x1E\x50-\x57\xFC\xFD]+/gcs;  # Skip some register pushes, cld, std.
  # TODO(pts): Add skipping of (sub sp, ...) for local variables.
  return unpack("C", $1) if
      $data =~ /\G\xB8(.)\x4C\xCD\x21/gcs or  # mov ax, 0x4c??;; int 0x21
      $data =~ /\G\xB4\x4C\xB0(.)\xCD\x21/gcs or  # mov ah, 0x4c;; mov al, 0x??;; int 0x21
      $data =~ /\G\xB0(.)\xB4\x4C\xCD\x21/gcs or  # mov al, 0x??;; mov ah, 0x4c;; int 0x21
      $data =~ /\G\xB8(.).\xC3/gcs or  # mov ax, 0x--??;; ret
      $data =~ /\G\xB0(.)\xC3/gcs;  # mov al, 0x??;; ret
  undef
}

# Regexp matching 80286 instructions, including 80287, but excluding
# protected mode. Prefixes are considered separate instructions.
my $INST_80286_RE = q(\x26\x2E\x36\x3E\x9B\xF0\xF2\xF3]|[\x06\x07\x0E\x16\x17\x1E\x1F\x27\x2F\x37\x3F-\x61\x6C-\x6F\x90-\x99\x9C-\x9F\xA4-\xA7\xAA-\xAF\xC3\xC9\xCB\xCC\xCE\xCF\xD6\xD7\xEC-\xEF\xF1\xF4\xF5\xF8-\xFD]|[\x04\x0C\x14\x1C\x24\x2C\x34\x3C\x6A\x70-\x7F\xA8\xB0-\xB7\xCD\xD4\xD5\xE0-\xE7\xEB][\x00-\xFF]|[\x62\x8D\xC4\xC5\xDA][\x00-\x05\x07-\x0D\x0F-\x15\x17-\x1D\x1F-\x25\x27-\x2D\x2F-\x35\x37-\x3D\x3F]|[\x00-\x03\x08-\x0B\x10-\x13\x18-\x1B\x20-\x23\x28-\x2B\x30-\x33\x38-\x3B\x84-\x8C\x8E\xD8][\x00-\x05\x07-\x0D\x0F-\x15\x17-\x1D\x1F-\x25\x27-\x2D\x2F-\x35\x37-\x3D\x3F\xC0-\xFF]|\xDE[\x00-\x05\x07-\x0D\x0F-\x15\x17-\x1D\x1F-\x25\x27-\x2D\x2F-\x35\x37-\x3D\x3F\xC0-\xCF\xD9\xE0-\xFF]|\xDC[\x00-\x05\x07-\x0D\x0F-\x15\x17-\x1D\x1F-\x25\x27-\x2D\x2F-\x35\x37-\x3D\x3F\xC0-\xCF\xE0-\xFF]|\xFF[\x00-\x05\x07-\x0D\x0F-\x15\x17-\x1D\x1F-\x25\x27-\x2D\x2F-\x35\x37\xC0-\xD7\xE0-\xE7\xF0-\xF7]|[\xD0-\xD3][\x00-\x05\x07-\x0D\x0F-\x15\x17-\x1D\x1F-\x25\x27-\x2D\x2F\x38-\x3D\x3F\xC0-\xEF\xF8-\xFF]|\xFE[\x00-\x05\x07-\x0D\x0F\xC0-\xCF]|\xD9[\x00-\x05\x07\x10-\x15\x17-\x1D\x1F-\x25\x27-\x2D\x2F-\x35\x37-\x3D\x3F\xC0-\xD0\xE0\xE1\xE4\xE5\xE8-\xEE\xF0-\xF4\xF6-\xFA\xFC\xFD]|\xDF[\x00-\x05\x07\x10-\x15\x17-\x1D\x1F-\x25\x27-\x2D\x2F-\x35\x37-\x3D\x3F\xC0-\xC7\xE0]|\xDD[\x00-\x05\x07\x10-\x15\x17-\x1D\x1F-\x25\x27\x30-\x35\x37-\x3D\x3F\xC0-\xC7\xD0-\xDF]|\xDB[\x00-\x05\x07\x10-\x15\x17-\x1D\x1F\x28-\x2D\x2F\x38-\x3D\x3F\xE0-\xE3]|\x8F[\x00-\x05\x07\xC0-\xC7]|\x0F[\x0B\xFF]|[\xF6\xF7][\x10-\x15\x17-\x1D\x1F-\x25\x27-\x2D\x2F-\x35\x37-\x3D\x3F\xD0-\xFF]|[\x05\x0D\x15\x1D\x25\x2D\x35\x3D\x68\xA0-\xA3\xA9\xB8-\xBF\xC2\xCA\xE8\xE9][\x00-\xFF]{2}|[\x6B\x80\x83][\x00-\x05\x07-\x0D\x0F-\x15\x17-\x1D\x1F-\x25\x27-\x2D\x2F-\x35\x37-\x3D\x3F\xC0-\xFF][\x00-\xFF]|[\xC0\xC1][\x00-\x05\x07-\x0D\x0F-\x15\x17-\x1D\x1F-\x25\x27-\x2D\x2F\x38-\x3D\x3F\xC0-\xEF\xF8-\xFF][\x00-\xFF]|\xF6[\x00-\x05\x07\x50-\x7F\xC0-\xC7][\x00-\xFF]|\xC6[\x00-\x05\x07\xC0-\xC7][\x00-\xFF]|\x8F[\x40-\x47][\x00-\xFF]|\xFE[\x40-\x4F][\x00-\xFF]|\xFF[\x40-\x77][\x00-\xFF]|[\x00-\x03\x08-\x0B\x10-\x13\x18-\x1B\x20-\x23\x28-\x2B\x30-\x33\x38-\x3B\x62\x84-\x8E\xC4\xC5\xD8\xDA\xDC\xDE][\x40-\x7F][\x00-\xFF]|[\xD0-\xD3][\x40-\x6F\x78-\x7F][\x00-\xFF]|[\xD9\xDF][\x40-\x47\x50-\x7F][\x00-\xFF]|\xDD[\x40-\x47\x50-\x67\x70-\x7F][\x00-\xFF]|\xDB[\x40-\x47\x50-\x5F\x68-\x6F\x78-\x7F][\x00-\xFF]|\xF7[\x50-\x7F][\x00-\xFF]|\xC8[\x00-\xFF]{3}|[\x69\x81][\x00-\x05\x07-\x0D\x0F-\x15\x17-\x1D\x1F-\x25\x27-\x2D\x2F-\x35\x37-\x3D\x3F\xC0-\xFF][\x00-\xFF]{2}|\xF7[\x00-\x05\x07\x16\x1E\x26\x2E\x36\x3E\x90-\xC7][\x00-\xFF]{2}|\xC7[\x00-\x05\x07\xC0-\xC7][\x00-\xFF]{2}|[\x00-\x03\x08-\x0B\x10-\x13\x18-\x1B\x20-\x23\x28-\x2B\x30-\x33\x38-\x3B\x62\x84-\x8E\xC4\xC5\xD8\xDA\xDC\xDE][\x06\x0E\x16\x1E\x26\x2E\x36\x3E\x80-\xBF][\x00-\xFF]{2}|\xFF[\x06\x0E\x16\x1E\x26\x2E\x36\x80-\xB7][\x00-\xFF]{2}|[\xD0-\xD3][\x06\x0E\x16\x1E\x26\x2E\x3E\x80-\xAF\xB8-\xBF][\x00-\xFF]{2}|\xFE[\x06\x0E\x80-\x8F][\x00-\xFF]{2}|[\xD9\xDF][\x06\x16\x1E\x26\x2E\x36\x3E\x80-\x87\x90-\xBF][\x00-\xFF]{2}|\xDD[\x06\x16\x1E\x26\x36\x3E\x80-\x87\x90-\xA7\xB0-\xBF][\x00-\xFF]{2}|\xDB[\x06\x16\x1E\x2E\x3E\x80-\x87\x90-\x9F\xA8-\xAF\xB8-\xBF][\x00-\xFF]{2}|\x8F[\x06\x80-\x87][\x00-\xFF]{2}|\xF6[\x16\x1E\x26\x2E\x36\x3E\x40-\x47\x90-\xBF][\x00-\xFF]{2}|\xC6[\x40-\x47][\x00-\xFF]{2}|[\x6B\x80\x83][\x40-\x7F][\x00-\xFF]{2}|[\xC0\xC1][\x40-\x6F\x78-\x7F][\x00-\xFF]{2}|\x0F[\x78\x79][\x00-\xFF]{2}|[\x9A\xEA][\x00-\xFF]{4}|[\x6B\x80\x83][\x06\x0E\x16\x1E\x26\x2E\x36\x3E\x80-\xBF][\x00-\xFF]{3}|[\xC0\xC1][\x06\x0E\x16\x1E\x26\x2E\x3E\x80-\xAF\xB8-\xBF][\x00-\xFF]{3}|[\xC6\xF6][\x06\x80-\x87][\x00-\xFF]{3}|[\xC7\xF7][\x40-\x47][\x00-\xFF]{3}|[\x69\x81][\x40-\x7F][\x00-\xFF]{3}|\x0F[\x78\x79][\x00-\xFF]{3}|[\x69\x81][\x06\x0E\x16\x1E\x26\x2E\x36\x3E\x80-\xBF][\x00-\xFF]{4}|[\xC7\xF7][\x06\x80-\x87][\x00-\xFF]{4});
# Regexp maching a 8086 string instruction.
my $STR_INST_80286_RE = q([\x6C-\x6F\xA4-\xA7\xAA-\xAF]);

# Checks the following (for simplicity):
#
# * All relative relocations have a 0 base.
# * $data is a concatenation of 80286 instructions, including 80287
#   floating point instructions, but excluding protected mode
#   instructions. (We check that there are no unknown opcodes or
#   i386+-only opcodes.)
# * There are are no split offsets in the middle of an
#   instruction. Splits are at labels (@$symbolsr) and after relative
#   relocations.
# * There are no relative jump/call targets outside the range of $data
#   (jumping right after $data is OK).
# * There are no relative jump/call targets in the middle of an instruction.
#
# Returns "" for simple code without string instructions, 0 for simple code
# with string instructions, a message explaining the complicatedness
# otherwise.
sub is_complicated_8086_code($$$) {
  my($data, $fixupr, $symbolsr) = @_;
  my $size = length($data);
  # 1-byte relative jumps: [\x70-\x7F\xE3\xEB].
  # 2-byte relative jumps and calls: [\xE8\xE9]..
  my @splits;
  for my $fixup (@$fixupr) {
    my($endofs, $ofs, $ltypem, $symbol) = @$fixup;
    return "relative fixup with nonzero base" if $ltypem < 0 and substr($data, $ofs, 2) ne "\0\0";
    push @splits, $endofs if $ltypem < 0;
  }
  push @splits, map { $_->[0] } @$symbolsr;
  push @splits, $size;  # Sentinel.
  @splits = sort { $a <=> $b } @splits;
  my $si = 0;
  pos($data) = 0;
  my @relative_splits;
  my $result = "";
  while ($data =~ m@\G(
      [\x70-\x7F\xE3\xEB]([\x00-\xFF]) |  # 1-byte replative jumps ($2).
      [\xE8\xE9]([\x00-\xFF]{2}) |  # 2-byte replative jump/call ($3).
      ($STR_INST_80286_RE) |  # 80286 string instruction ($4).
      $INST_80286_RE)@gcxo) {
    my $endpos = pos($data);
    while ($endpos > $splits[$si]) {
      #print STDERR "warning: split instruction: $pos...$endpos [$si]=$splits[$si]\n" if $pos != $splits[$si];
      return "split instruction" if $endpos - length($1) != $splits[$si];
      ++$si;
    }
    if (defined($2) or defined($3)) {  # 1-byte relative jump.
      my $target;
      if (defined($2)) {
        $target = $endpos + unpack("c", $2);
      } else {
        $target = unpack("v", $3);
        $target = $endpos + $target - (($target & 0x8000) << 1);
      }
      if ($target != $endpos) {  # Shortcut, this would always succeed.
        return "relative jump/call target out of range" if $target < 0 or $target > $size;
        push @relative_splits, $target;
      }
    } elsif (defined($4)) {
      $result = 0;  # String instruction detected.
    }
  }
  return "unknown instruction" if pos($data) != $size;
  if (@relative_splits) {
    @splits = sort { $a <=> $b } @relative_splits;
    push @splits, $size;  # Sentinel.
    @relative_splits = ();  # Save memory.
    $si = 0; pos($data) = 0;
    while ($data =~ m@\G($INST_80286_RE)@gco) {
      my $endpos = pos($data);
      while ($endpos > $splits[$si]) {
        #print STDERR "warning: split target instruction: $pos...$endpos [$si]=$splits[$si]\n" if $pos != $splits[$si];
        return "split target instruction" if $endpos - length($1) != $splits[$si];
        ++$si;
      }
    }
    return "unknown instruction" if pos($data) != $size;  # Should happen above, not here.
  }
  $result
}

my %LINKER_FLAG_OK = map { $_ => 1 } qw(omit_cld uninitialized_bss start_es_psp);
my @SEGMENT_ORDER = qw(_TEXT CONST CONST2 _DATA _BSS);  # Constant, OpenWatcom wcc.
my %SEGMENT_NAME_OK = map { $_ => 1 } @SEGMENT_ORDER;
my %ASM_DATA_OP = (1 => "db", 2 => "dw", 4 => "dd", 8 => "dq");  # Constant, nasm.

sub emit_nasm_segment($$$$$$) {
  my($segment_name, $exef, $size, $data, $symbolsr, $fixupr) = @_;
  print $exef "S\$${segment_name}:\n";
  print $exef "SSIZE\$${segment_name} equ $size\n";  # Not needed, just FYI.

  # Sort by ofs ascending.
  my @symbols = sort { $a->[0] <=> $b->[0] or $a->[1] cmp $b->[1] } @$symbolsr;
  my $fi = 0; my $si = 0; my $i = 0;  # $fixupr is already sorted.
  my $is_bss = $segment_name eq "_BSS";
  my $chunk_sub = $segment_name eq "_BSS" ? sub { my $size = $_[0] - $i; print $exef "resb $size\n"; $i = $_[0]; } : sub {
    my $j = $_[0];
    while ($fi < @$fixupr and $fixupr->[$fi][1] < $j) {  # Apply fixup.
      my($endofs, $ofs, $ltypem, $symbol) = @{$fixupr->[$fi++]};
      my $line = unpack("H*", substr($data, $i, $ofs - $i)); $line =~ s@(..)(?=.)@$1, 0x@sg; print $exef "db 0x$line\n";
      my $base = sprintf("0x%x", unpack("v", substr($data, $ofs, 2)));
      my $size = $endofs - $ofs;
      my $rel = $ltypem < 0 ? "-(\$+$size)" : "";
      print $exef "$ASM_DATA_OP{$size} $base+$symbol$rel\n";
      $i = $endofs;
    }
    if ($i < $j) {
      my $line = unpack("H*", substr($data, $i, $j - $i)); $line =~ s@(..)(?=.)@$1, 0x@sg; print $exef "db 0x$line\n";
      $i = $j;
    }
  };
  while ($si < @symbols) {
    my $j = $symbols[$si][0];
    if ($j > $size or $j < $i) {
      print $exef "$symbols[$si][1] equ $j+S\$_${segment_name}\n";
      ++$si; next
    }
    $chunk_sub->($j) if $j > $i;
    for (; $si < @symbols and $symbols[$si][0] == $j; ++$si) {
      print $exef "$symbols[$si][1]:\n";
    }
  }
  $chunk_sub->($size) if $size > $i;
}

# OMF .obj record types to keep in .lib files.
my %LIB_RECORD_TYPES = map { $_ => 1 } 0x96, 0x98, 0xa0, 0x90, 0xb6, 0x8c, 0xb4, 0x9c, 0x8a;
my %LIB_OMITTED_RECORD_TYPES = map { $_ => 1 } 0x80, 0x82, 0x88, 0x9a;
my %LIB_DISALLOWED_RECORD_TYPES = map { $_ => 1 } 0xa1, 0x91, 0xb7, 0xb5, 0x9d, 0x8b;
my $empty_lheadr = "\x82\x02\x00\x00\x7c";

# Copies OMF .obj file from one file to the other, keeping only known
# records, and ensuring deterministic output by removing records with
# timestamp (e.g. COMENT 0xE9 -- Borland dependency).
sub filter_obj_to_lib($$) {
  my($objfn, $libf) = @_;
  my $f;  # Of OMF .obj format, typically created by wcc or `nasm -f obj'.
  my $type = -1;
  eval {
  die "$0: fatal: cannot open obj file for reading: $objfn\n" if !open($f, "<", $objfn);
  binmode($f);  # Needed everywhere for Win32 compatibility.
  while (1) {
    my($data, $size);
    die "$0: fatal: EOF in obj record header\n" if (read($f, $data, 3) or 0) != 3;
    ($type, $size) = unpack("Cv", $data);
    die "$0: fatal: empty obj record\n" if !$size;
    #printf STDERR "info: RECORD 0x%x %d\n", $type, $size;
    die "$0: fatal: EOF in obj record header\n" if (read($f, $data, $size, 3) or 0) != $size;
    if (exists($LIB_RECORD_TYPES{$type})) {
      print $libf $data;
    } elsif (exists($LIB_OMITTED_RECORD_TYPES{$type})) {
    } elsif (exists($LIB_DISALLOWED_RECORD_TYPES{$type})) {
      die sprintf("%s: fatal: disallowed obj record type: type=0x%x size=%d\n", $0, $type, $size - 1);
    } else {
      die sprintf("%s: fatal: unsupported obj record type: type=0x%x size=%d\n", $0, $type, $size - 1);
    }
    # --$size; substr($data, -1) = "";  # Ignore checksum.
    last if $type == 0x8a;  # MODEND.
  }
  };  # End of eval block.
  close($f) if $f;
  die $@ if $@;
  print $libf "\x8a\x02\x00\x00\x74" if $type != 0x8a and $type >= 0;  # Simulate MODEND.
}

sub build_static_library($@) {
  my $libfn = shift(@_);  # @_ contains @objfns.
  my $libf;
  eval {
  die "$0: fatal: cannot open for writing: $libfn\n" if !open($libf, ">", $libfn);
  binmode($libf);
  print $libf $empty_lheadr;  # Signature.
  for my $objfn (@_) {
    filter_obj_to_lib($objfn, $libf);
  }
  # TODO(pts): Better detect output errors in $libf.
  if ($libf and !close($libf)) { $libf = undef; die "$0: fatal: cannot close output file: $libfn\n"; }
  $libf = undef;
  };  # End of eval block.
  close($libf) if $libf;
  if ($@) { print STDERR $@; exit(8); }
}

# Loads an OMF .obj file or a .lib file. This function may misbehave for
# .obj and .lib files not created by (wcc, nasm or wasm) invoked by dosmc. However,
# .obj output of other assemblers may work, see examples/helloc2*.asm for examples.
# Based on: https://pierrelib.pagesperso-orange.fr/exec_formats/OMF_v1.1.pdf
sub load_obj($$) {
  my($objfn, $objli) = @_;
  my @objs;  # Result. ([\%undefined_symbols, \%segment_symbols, \%ledata, \%segment_sizes, \%fixupp, $has_string_instructions], ...).
  my $f;  # Of OMF .obj format, typically created by wcc or `nasm -f obj'.
  my $had_lheadr = 0;
  my $is_just_after_modend = 0;
  eval {
  die "$0: fatal: cannot open obj or lib file for reading: $objfn\n" if !open($f, "<", $objfn);
  binmode($f);
  while (1) {  # Read next module (.obj within .lib).
  my $obj_symbol_prefix = "O$objli\$"; ++$objli;
  my @lnames = ("-LN0");
  my %segment_sizes;
  my @segment_names = ("-SN");
  my %ledata = map { $_ => "" } @SEGMENT_ORDER;  # $segment_name => $ledata_str.
  my %symbol_ofs;   # $symbol => $ofs. Offset is within its section.
  my %text_symbol_ofs;   # $symbol => $ofs. Offset is within section _TEXT.
  my %segment_symbols = map { $_ => [] } @SEGMENT_ORDER;  # $segment_name => [[$ofs, $symbol], ...].
  my @extdef = ("-ED");
  my %fixupp = map { $_ => [] } @SEGMENT_ORDER;  # $segment_name => [[$endofs, $ofs, $ltypem, $symbol], ...].
  my $has_string_instructions = 0;
  my($last_segment_name, $last_ofs);
  while (1) {  # Read next .obj record.
    my $data;
    if ((read($f, $data, 3) or 0) != 3) {
      last if $is_just_after_modend;
      die "$0: fatal: EOF in obj record header\n";
    }
    $is_just_after_modend = 0;
    my($type, $size) = unpack("Cv", $data);
    die "$0: fatal: empty obj record\n" if !$size;
    #printf STDERR "info: RECORD 0x%x %d\n", $type, $size;
    die "$0: fatal: EOF in obj record header\n" if (read($f, $data, $size) or 0) != $size;
    --$size; substr($data, -1) = "";  # Ignore checksum.
    # Maintenance note: If useful action is added for a new $type here, also
    # add the $type value to %LIB_RECORD_TYPES.
    if ($type == 0x96) {  # LNAMES.
      for (my $i = 0; $i < $size; ) {
        my $fsize = vec($data, $i++, 8);
        die "$0: fatal: EOF in LNAMES name\n" if $i + $fsize > $size;
        push(@lnames, $fsize == 0 ? "-LNEMPTY" : substr($data, $i, $fsize));
        $i += $fsize;
      }
    } elsif ($type == 0x98) {  # SEGDEF.
      die "$0: fatal: SEGDEF too short" if $size < 6;
      my $attr = vec($data, 0, 8);
      die "$0: fatal: unsupported alignment\n" if ($attr >> 5) == 0;
      my $is_big = ($attr >> 1) & 1;
      my($segment_size, $segment_name_idx) = unpack("vC", substr($data, 1, 3));
      die "$0: fatal: bad segment_name_idx\n" if $segment_name_idx >= @lnames;
      $segment_size = 0x10000 if $is_big;
      # .obj output of wcc doesn't need uc and _ prefix, but output of nasm may need it.
      my $segment_name = uc($lnames[$segment_name_idx]);
      $segment_name =~ s@\A[_.]+@@;
      $segment_name = "TEXT" if $segment_name eq "CODE";
      substr($segment_name, 0, 0) = "_" if $segment_name !~ m@\ACONST@;
      die "$0: fatal: unsupported segment: $segment_name\n" if !$SEGMENT_NAME_OK{$segment_name};
      #print STDERR "info: SEGDEF $segment_name\n";
      # Example alternative spellings: .bss and _BSS.
      die "$0: fatal: duplicate segment (maybe alternative spellings?): $segment_name\n" if exists($segment_sizes{$segment_name});
      $segment_sizes{$segment_name} = $segment_size;
      # Some segment indexes would become 2 bytes, we do not support that.
      die "$0: fatal: too many segments\n" if @segment_names >= 127;
      push @segment_names, $segment_name;
      #print STDERR "info: SEGDEF: $segment_name size=$segment_size\n";
    } elsif ($type == 0x99) {  # Long SEGDEF.
      die "$0: fatal: long SEGDEF not supported\n";
    } elsif ($type == 0xa0) {  # LEDATA.
      die "$0: fatal: LEDATA too short" if $size < 3;
      my($segment_idx, $ofs) = unpack("Cv", substr($data, 0, 3));
      die "$0: fatal: unknown segment: $segment_idx\n" if !$segment_idx or $segment_idx >= @segment_names;
      my $segment_name = $segment_names[$segment_idx];
      $size -= 3; substr($data, 0, 3) = "";
      #print STDERR "info: LEDATA: $segment_name ofs=$ofs size=$size\n";
      die "$0: fatal: gap in LEDATA for $segment_name\n" if length($ledata{$segment_name}) != $ofs;
      $ledata{$segment_name} .= $data;
      $last_segment_name = $segment_name;  $last_ofs = $ofs;  # For FIXUPP.
    } elsif ($type == 0xa1) {  # Long LEDATA.
      die "$0: fatal: long LEDATA not supported\n";
    } elsif ($type == 0x90 or $type == 0xb6) {  # PUBDEF or LPUBDEF(static).
      my $recname = $type == 0xb6 ? "LPUBDEF" : "PUBDEF";
      # $ as a prefix would make nasm to treat it as a symbol name, e.g. $ax
      # as ax. A $ in the middle of the symbol name ias also good to force
      # it to be a symbol in nasm.
      my $symbol_prefix = $type == 0xb6 ? $obj_symbol_prefix : "G\$";
      die "$0: fatal: $recname too short" if $size < 2;
      my $segment_idx = vec($data, 1, 8);
      if ($segment_idx == 0) {  # 0: .wasm source with `PUBLIC ...', but label not defined. Ignore.
      } else {
        die "$0: fatal: unknown segment: $segment_idx\n" if !$segment_idx or $segment_idx >= @segment_names;
        my $segment_name = $segment_names[$segment_idx];
        for (my $i = 2; $i < $size; $i += 3) {
          my $fsize = vec($data, $i++, 8);
          die "$0: fatal: EOF in $recname entry\n" if $i + $fsize + 3 > $size;
          my $symbol = $symbol_prefix . substr($data, $i, $fsize);
          $i += $fsize;
          my($ofs, $type) = unpack("vC", substr($data, $i, 3));
          #print STDERR "info: $recname $segment_name $symbol $ofs $type\n";
          # Also because we do not support parsing 2-byte type index.
          die "$0: fatal: bad symbol type: symbol=$symbol type=$type\n" if $type != 0;
          die "$0: fatal: duplicate symbol within obj: $symbol\n" if exists($symbol_ofs{$symbol});
          $symbol_ofs{$symbol} = $ofs;
          $text_symbol_ofs{$symbol} = $ofs if $segment_name eq "_TEXT";
          push @{$segment_symbols{$segment_name}}, [$ofs, $symbol];
        }
      }
    } elsif ($type == 0x91) {  # Long PUBDEF.
      die "$0: fatal: long PUBDEF not supported\n";
    } elsif ($type == 0xb7) {  # Long LPUBDEF.
      die "$0: fatal: long LPUBDEF not supported\n";
    } elsif ($type == 0x8c or $type == 0xb4) {  # EXTDEF or LEXTDEF(static).
      my $recname = $type == 0xb4 ? "LEXTDEF" : "EXTDEF";
      # $ is for nasm to treat it as a symbol name, e.g. $ax as ax.
      my $symbol_prefix = $type == 0xb4 ? $obj_symbol_prefix : "G\$";
      for (my $i = 0; $i < $size; ) {
        my $fsize = vec($data, $i++, 8);
        die "$0: fatal: EOF in $recname entry\n" if $i + $fsize + 1 > $size;
        # $ is for nasm to take the symbol as an identifier.
        my $symbol = $symbol_prefix . substr($data, $i, $fsize);
        $i += $fsize;
        my $type = unpack("C", substr($data, $i++, 1));
        # Also because we do not support parsing 2-byte type index.
        die "$0: fatal: unsupported $recname type: symbol=$symbol type=$type\n" if $type != 0;
        #print STDERR "info: $recname $symbol $type\n";
        push @extdef, $symbol;
      }
    } elsif ($type == 0xb5) {  # Long LEXTDEF.
      die "$0: fatal: long LEXTDEF not supported\n";
    } elsif ($type == 0x9c) {  # FIXUPP.
      die "$0: fatal: FIXUPP must follow LEDATA\n" if !defined($last_ofs);
      die "$0: fatal: FIXUPP not allowed in _BSS" if $last_segment_name eq "_BSS";
      for (my $i = 0; $i < $size; ) {
        die "$0: fatal: EOF in FIXUP header\n" if $i + 3 > $size;
        my ($a, $ofs, $fd) = unpack("CCC", substr($data, $i, 3));
        #print STDERR "info: FIXUPP bytes " . unpack("H*", substr($data, $i, 3)) . "\n";
        #printf STDERR "info: FIXUPP a=0x%x dro=0x%x fd=0x%x\n", $a, $ofs, $fd;
        $i += 3;
        die "$0: fatal: THREAD subrecord not supported\n" if !($a & 0x80);
        die "$0: fatal: frame thread not supported\n" if $fd & 0x80;
        die "$0: fatal: target thread not supported\n" if $fd & 8;
        my $is_self = ~($a >> 6) & 1;
        my $ltype = ($a >> 2) & 15;
        my $lsize = $ltype == 1 ? 2 : undef;
        die "$0: fatal: unsupported FIXUPP location type: $ltype\n" if !defined($lsize);
        my $ltypem = $is_self ? -$ltype : $ltype;
        $ofs = $last_ofs + ($ofs | ($a & 3) << 8);
        my $endofs = $ofs + $lsize;
        die "$0: fatal: FIXUPP data record offset too large\n" if
            $endofs > length($ledata{$last_segment_name});
        my $frame = ($fd >> 4) & 7;
        my $target = $fd & 7;
        my $fixuppr = $fixupp{$last_segment_name};
        die "$0: fatal: FIXUPP must not overlap\n" if @$fixuppr and $fixuppr->[-1][0] > $ofs;
        my $symbol;
        if ($frame == 5 and $target == 6) {
          die "$0: fatal: EOF in FIXUPP target\n" if $i >= $size;
          my $extdef_idx = vec($data, $i++, 8);
          if ($extdef_idx >= 0x80) {
            die "$0: fatal: EOF in FIXUPP target 2-byte extdef_idx\n" if $i >= $size;
            $extdef_idx = ($extdef_idx - 0x80) << 8 | vec($data, $i++, 8);
          }
          die "$0: fatal: FIXUPP EXTDEF index is 0\n" if $extdef_idx == 0;
          die "$0: fatal: unknown FIXUPP EXTDEF index: $extdef_idx\n" if $extdef_idx >= @extdef;
          $symbol = $extdef[$extdef_idx];
          #print STDERR "info: FIXUPP 16-bit $is_self \@$ofs EXTDEF $symbol\n";
        } elsif (($target == 0 or $target == 4) and (
                  $frame == 1 or  # Segment CONST in DGROUP, by wcc, with $target == 4.
                  $frame == 5 or  # Segment CONST, by nasm, with $target == 4.
                  $frame == 0)) {  # Segment CONST and _BSS, by MASM 4.00, with $target == 4 and $target == 0.
          # We usually get it for string literals in CONST.
          die "$0: fatal: EOF in FIXUPP target\n" if $i + ($frame == 5 ? 1 : 2) > $size;
          ++$i if $frame == 1;  # Skip group index.
          my $segment_idx = vec($data, $i++, 8);
          die "$0: fatal: segment index mismatch in FIXUPP\n" if
              $frame == 0 and $segment_idx != vec($data, $i++, 8);  # Skip duplicate segment index.
          die "$0: fatal: unknown segment: $segment_idx\n" if !$segment_idx or $segment_idx >= @segment_names;
          my $segment_name = $segment_names[$segment_idx];
          #print STDERR "info: FIXUPP 16-bit $is_self \@$ofs SEGMENT $segment_name\n";
          $symbol = "OS\$${segment_name}";
          if ($target == 0) {  # 2-byte displacement.
            die "$0: fatal: EOF in FIXUPP displacement\n" if $i + 2 > $size;
            my $dofs = unpack("v", substr($data, $i, 2)); $i += 2;
            substr($ledata{$last_segment_name}, $ofs, 2) = pack("v", unpack("v", substr($ledata{$last_segment_name}, $ofs, 2)) + $dofs) if $dofs;
          }
        } else {
          die "$0: fatal: unsupported FIXUPP: frame=$frame target=$target\n";
        }
        push @$fixuppr, [$endofs, $ofs, $ltypem, $symbol];
      }
    } elsif ($type == 0x9d) {  # Long FIXUPP.
      die "$0: fatal: long FIXUPP not supported\n";
    } elsif ($type == 0x8a) {  # MODEND.
      if ($size) {
        my $b = vec($data, 0, 8);
        if (($b & 0xc1) == 0xc1) {
          die "$0: fatal: EOF in MODEND entry point\n" if $size < 2;
          $b = vec($data, 1, 8);
          my $segment_idx;
          if ($b == 0) {  # $frame = 0; $target = 0;
            die "$0: fatal: bad MODEND size\n" if $size != 6;
            $segment_idx = vec($data, 2, 8); my $segment_idx2 = vec($data, 3, 8);  # frame data, target data.
            die "$0: fatal: segment index mismatch in MODEND\n" if $segment_idx != $segment_idx2;
          } elsif ($b == 0x50) {  # .obj created by WASM. $frame = 5; $target = 0;
            die "$0: fatal: bad MODEND size\n" if $size != 5;
            $segment_idx = vec($data, 2, 8);  # target data.
          } else {
            die "$0: fatal: unsupported MODEND fix data: " . sprintf("0x%x", $b). "\n";
          }
          die "$0: fatal: unknown segment: $segment_idx\n" if !$segment_idx or $segment_idx >= @segment_names;
          my $segment_name = $segment_names[$segment_idx];
          die "$0: fatal: expecting _TEXT in MODEND entry point\n" if $segment_name ne "_TEXT";
          my $ofs = unpack("v", substr($data, -2, 2));
          my $symbol = "G\$_start_";
          die "$0: fatal: conflicting entry point symbol within obj: $objfn: " . substr($symbol, 2) . "\n" if
              exists($symbol_ofs{$symbol}) and !(exists($text_symbol_ofs{$symbol}) and $text_symbol_ofs{$symbol} == $ofs);
          if (!exists($symbol_ofs{$symbol})) {
            $text_symbol_ofs{$symbol} = $symbol_ofs{$symbol} = $ofs;
            push @{$segment_symbols{$segment_name}}, [$ofs, $symbol];
          }
        } elsif ($b & 0x40) {
          die "$0: fatal: unsupported MODEND mattr: " . sprintf("0x%x", $b). "\n";
        }
      }
      last
    } elsif ($type == 0x8b) {  # Long MODEND.
      die "$0: fatal: long MODEND not supported\n";
    # Maintenance note: If useful action is added for a new $type here, also
    # add the $type value to %LIB_RECORD_TYPES.
    } elsif ($type == 0x80) {  # THEADR. Also omit from .lib files.
    } elsif ($type == 0x82) {  # LHEADR. Also omit from .lib files. Present at the beginning of .lib files created by build_static_library.
      $had_lheadr = 1;
    } elsif ($type == 0x88) {  # COMENT. Also omit from .lib files.
    } elsif ($type == 0x9a) {  # GRPDEF. Also omit from .lib files.
    } else {
      # We do not need to support common symbols, wcc never generates them.
      die sprintf("%s: fatal: unsupported obj record type: type=0x%x size=%d\n", $0, $type, $size);
    }
    $last_segment_name = $last_ofs = undef if $type != 0xa0 and $type != 0xa1 and $type != 0x9c;
  }  # .obj record.
  last if $is_just_after_modend;
  my $code_type = is_complicated_8086_code($ledata{_TEXT}, $fixupp{_TEXT}, $segment_symbols{_TEXT});
  if ($code_type) {  # Complicated.
    $has_string_instructions = 1 if $ledata{_TEXT} =~ m@$STR_INST_80286_RE@o;  # Conservative.
  } else {
    $has_string_instructions = 1 if length($code_type);
  }
  for my $segment_name (@SEGMENT_ORDER) {
    # Typically $segment_sizes{_BSS} is missing, put it back.
    $segment_sizes{$segment_name} = 0 if !exists($segment_sizes{$segment_name});
    my $size = $segment_name eq "_BSS" ? 0 : $segment_sizes{$segment_name};
    die "$0: assert: segment size mismatch for $segment_name\n" if
        length($ledata{$segment_name}) != $size;
  }
  my %undefined_symbols = map { $_ => 1 } @extdef;
  delete $undefined_symbols{$extdef[0]};
  for my $symbol (keys %symbol_ofs) {
    delete $undefined_symbols{$symbol};
  }
  my @nlu = grep { substr($_, 0, 2) ne "G\$" } sort keys %undefined_symbols;
  die "$0: fatal: found local undefined symbols in $objfn: @nlu\n" if @nlu;
  push @objs, [\%undefined_symbols, \%segment_symbols, \%ledata, \%segment_sizes, \%fixupp, $has_string_instructions];
  last if !$had_lheadr;
  $is_just_after_modend = 1;
  }  # Module (.obj).
  };  # End of eval block.
  close($f) if $f;
  die $@ if $@;
  @objs
}

sub link_executable($$$$@) {
  my($is_nasm, $exefn, $EXT, $nasm_cpu) = splice(@_, 0, 4);  # Keep .obj files in @_.
  local $0 = "dosmc-linker-$EXT" . ($is_nasm ? "-nasm" : "");
  die "$0: assert: unknown EXT: $EXT\n" if $EXT ne "exe" and $EXT ne "com";
  my %undefined_symbols;
  my %symbol_ofs;   # $symbol => $ofs. Offset is within its section.
  my %text_symbol_ofs;   # $symbol => $ofs. Offset is within section _TEXT.
  my %segment_symbols = map { $_ => [] } @SEGMENT_ORDER;  # $segment_name => [[$ofs, $symbol], ...].
  my %ledata = map { $_ => "" } @SEGMENT_ORDER;  # $segment_name => $ledata_str.
  my %fixupp = map { $_ => [] } @SEGMENT_ORDER;  # $segment_name => [[$endofs, $ofs, $ltypem, $symbol], ...].
  my %segment_sizes = map { $_ => 0 } @SEGMENT_ORDER;  # $segment_name => $byte_size.
  my $has_string_instructions = 0;
  my $do_use_argc = 0;
  my @objs;
  my $objfni = 0;
  my $objli = 1;
  my %lf;  # Linker flags.
  my %unknown_lf;
  my $obji_base = -1;
  my %duplicate_symbols;
  #print STDERR "info: first round\n";
  while (@_) {  # Next round.
    my @skipped_objs;
    my $skipped_objs_base = 0;
    my $obji = 0;
    my $used_objs_base = 0;
    my $obji_base = 0;
    while (1) {  # Process next .obj within this round.
      if ($obji == @objs) {
        last if $objfni == @_;
        my $load_obj_count = @objs;
        push @objs, load_obj($_[$objfni++], $objli), undef;
        $load_obj_count = @objs - $load_obj_count;
        $objli += $load_obj_count;
        #print STDERR "info: loaded @{[$load_obj_count-1]} objs from $_[$objfni-1]\n";
      }
      my $obj = $objs[$obji++];
      if (!defined($obj)) {  # Separates input files.
        my $skipped_objc = @skipped_objs - $skipped_objs_base;
        if ($skipped_objc and $used_objs_base) {  # Same input file (usually .lib) had skipped and non-skipped objs.
          #print STDERR "info: restart half-round\n";
          splice @objs, $obji_base, @objs - $obji_base, splice(@skipped_objs, $skipped_objs_base, $skipped_objc), undef;
          $obji = $obji_base; $used_objs_base = 0; next  # Do another half-round using objs from the same .lib file.
        }
        #print STDERR "info: next input\n";
        push @skipped_objs, undef; $skipped_objs_base = @skipped_objs; $used_objs_base = 0; $obji_base = $obji; next;
      }
      my($obj_undefined_symbols, $obj_segment_symbols, $obj_ledata, $obj_segment_sizes, $obj_fixupp, $obj_has_string_instructions) = @$obj;
      if ($obji > 1 or $objfni > 1) {  # Check if this .obj has any new symbols.
        my $has_new_symbol = 0;
        for my $segment_name (@SEGMENT_ORDER) {
          for my $pair (@{$obj_segment_symbols->{$segment_name}}) {
            my($ofs, $symbol) = @$pair;
            if (exists($undefined_symbols{$symbol})) { $has_new_symbol = 1; last }
          }
          last if $has_new_symbol;
        }
        if (!$has_new_symbol) {  # Skip an .obj file if it doesn't define any new symbols.
          #print STDERR "info: skipped obj\n";
          push @skipped_objs, $obj;
          next;
        }
      }
      #print STDERR "info: used obj\n";
      ++$used_objs_base;
      # Helpfully added by wcc if there is main(...) with nonzero arguments.
      $do_use_argc = 1 if exists($obj_undefined_symbols->{"G\$__argc"});
      delete $obj_undefined_symbols->{"G\$__argc"};
      delete $obj_undefined_symbols->{"G\$_cstart_"};
      # _big_code_ indicates a memory model not supported by dosmc.
      die "$0: fatal: unexpected symbol: _big_code_\n" if exists($obj_undefined_symbols->{"G\$_big_code_"});
      delete $obj_undefined_symbols->{"G\$_small_code_"};  # Present if a C function is defined in this .obj file.
      $has_string_instructions |= $obj_has_string_instructions;
      my %old_segment_sizes = %segment_sizes;
      for my $segment_name (@SEGMENT_ORDER) {
        my $is_text = $segment_name eq "_TEXT";
        my $segment_ofs = $old_segment_sizes{$segment_name};
        my $segment_symbolsr = $segment_symbols{$segment_name};
        my $fixupr = $fixupp{$segment_name};
        for my $pair (@{$obj_segment_symbols->{$segment_name}}) {
          my($ofs, $symbol) = @$pair;
          if (exists($symbol_ofs{$symbol})) {
            $duplicate_symbols{$symbol} = 1;
          } else {
            $ofs += $segment_ofs;
            $symbol_ofs{$symbol} = $ofs;
            $text_symbol_ofs{$symbol} = $ofs if $is_text;
            push @$segment_symbolsr, [$ofs, $symbol];
            delete $undefined_symbols{$symbol};
          }
        }
        my $datar = \$obj_ledata->{$segment_name};
        for my $fixup (@{$obj_fixupp->{$segment_name}}) {  # Apply fixups.
          my($endofs, $ofs, $ltypem, $symbol) = @$fixup;
          substr($$datar, $ofs, 2) = pack("v", unpack("v", substr($$datar, $ofs, 2)) + $old_segment_sizes{$1}) if $symbol =~ s@\AOS\$(?=(.*))@S\$@s;
          push @$fixupr, [$endofs + $segment_ofs, $ofs + $segment_ofs, $ltypem, $symbol];
        }
        $ledata{$segment_name} .= $$datar;
        $segment_sizes{$segment_name} += $obj_segment_sizes->{$segment_name};
      }
      for my $symbol (sort keys %$obj_undefined_symbols) {
        if ($symbol =~ s@\AG\$__LINKER_FLAG_@@i) {  # Created by __LINKER_FLAG($symbol) in .c and .nasm files.
          $symbol = lc($symbol);  # Microsoft MASM 4.0 creates all symbols in uppercase.
          if (exists($LINKER_FLAG_OK{$symbol})) {
            $lf{$symbol} = 1;
          } else {
            $unknown_lf{$symbol} = 1;
          }
        } else {
          $undefined_symbols{$symbol} = 1 if !exists($symbol_ofs{$symbol});
        }
      }
    }
    last if @skipped_objs == @objs or !%undefined_symbols;
    @objs = @skipped_objs;
    #print STDERR "info: next round\n";
  }
  if (%undefined_symbols) {
    my @undefined_symbols = sort keys %undefined_symbols;
    my @nlu = grep { substr($_, 0, 2) ne "G\$" } @undefined_symbols;
    die "$0: fatal: found local undefined symbols: @nlu\n" if @nlu;
    my @lu = map { substr($_, 2) } @undefined_symbols;
    die "$0: fatal: undefined symbols: @lu\n";
  }
  if (%unknown_lf) {
    my @unknown_lf = sort keys %unknown_lf;
    die "$0: fatal: unknown linker flags: @unknown_lf\n";
  }
  if (%duplicate_symbols) {
    my @duplicate_symbols = sort keys %duplicate_symbols;
    my @nlu = grep { substr($_, 0, 2) ne "G\$" } @duplicate_symbols;
    # It should be a global, because object-local symbols are
    # prefixed with a unique $obj_symbol_prefix.
    die "$0: fatal: found local duplicate symbols: @nlu\n" if @nlu;
    my @lu = map { substr($_, 2) } @duplicate_symbols;
    die "$0: fatal: duplicate symbols: @lu\n";
  }

  my $entry_count = (defined($text_symbol_ofs{"G\$main_"}) + defined($text_symbol_ofs{"G\$_start_"}));
  die "$0: fatal: too many entry points (main functions)\n" if $entry_count > 1;
  die "$0: fatal: missing entry point (main function)\n" if $entry_count == 0;

  my $is_exe = $EXT eq "exe";  # Otherwise .com.
  my $exit_code = get_8086_exit_code($ledata{_TEXT}, \%text_symbol_ofs);
  if (defined($exit_code)) {  # Shortcut if the program immediately exits.
    for my $segment_name (@SEGMENT_ORDER) {
      $ledata{$segment_name} = ""; $segment_sizes{$segment_name} = 0; $fixupp{$segment_name} = []; $segment_symbols{$segment_name} = [];
    }
    delete $text_symbol_ofs{"G\$main_"};
    delete $symbol_ofs{"G\$main_"};
    $text_symbol_ofs{"G\$_start_"} = $symbol_ofs{"G\$_start_"} = 0;
    push @{$segment_symbols{_TEXT}}, [0, "_start_"];
    if ($is_exe or $exit_code) {
      $ledata{_TEXT} = pack("aCa3", "\xB8", $exit_code, "\x4C\xCD\x21");  # mov ax, 0x4c??;; int 0x21
    } else {
      $ledata{_TEXT} = "\xC3";  # ret
    }
    $segment_sizes{_TEXT} = length($ledata{_TEXT});
  }

  my $does_entry_point_return = !defined($exit_code);  # TODO(pts): Smarter detection.
  my $is_data_used = !defined($exit_code);
  my $need_clear_ax = (defined($text_symbol_ofs{"G\$main_"}) and $do_use_argc);
  my $do_clear_bss_with_code = (!$lf{uninitialized_bss} and $segment_sizes{_BSS} + ($need_clear_ax << 1) > 14);  # 14 == length($clear_bss_full).
  my $need_clear_df = ($do_clear_bss_with_code or (!$lf{omit_cld} and $has_string_instructions and !(
      defined($text_symbol_ofs{"G\$_start_"}) and substr($ledata{_TEXT}, $text_symbol_ofs{"G\$_start_"}, 1) =~ m@\A[\xFC\xFD]@  # cld or std.
      )));

  # _DATA comes before _BSS in @SEGMENT_ORDER, move all (\0) bytes from _BSS to _DATA.
  if (!$lf{uninitialized_bss} and !$do_clear_bss_with_code) { $ledata{_DATA} .= "\0" x $segment_sizes{_BSS}; $segment_sizes{_DATA} += $segment_sizes{_BSS}; $segment_sizes{_BSS} = 0; }
  for my $segment_name (@SEGMENT_ORDER) {
    die "$0: assert: segment size mismatch for $segment_name\n" if
        length($ledata{$segment_name}) != ($segment_name eq "_BSS" ? 0 : $segment_sizes{$segment_name});
  }

  my $exef;  # May be of .com, .exe or .nasm format.
  eval {
  die "$0: fatal: cannot open for writing: $exefn\n" if !open($exef, ">", $exefn);
  binmode($exef);
  if ($is_nasm) {  # emit_nasm.
    my($fullprog_code, $fullprog_data, $fullprog_bss, $fullprog_end);
    # No need to disambiguate NASM symbols like code_end, because
    # wcc adds _ prefix or suffix to all symbols (including static ones).
    if ($is_exe) {
# Based on https://github.com/pts/pts-nasm-fullprog/blob/master/fullprog_dosexe.inc.nasm
$fullprog_code = q(
section .text align=1 vstart=-0x10
; DOS .exe header, similar to: https://stackoverflow.com/q/14246493/97248
exe_header:
db 0x4d, 0x5a  ; MZ Signature.
dw ((code_end-exe_header)+(data_end-data_start))&511  ; Image size low 9 bits.
dw ((code_end-exe_header)+(data_end-data_start)+511)>>9  ; Image size high bits, including header and relocations (none here), excluding .bss, rounded up.
dw 0  ; Relocation count.
dw 1  ; Paragraph (16 byte) count of header. Points to code_startseg.
dw (bss_end-bss_start+15-(-((data_end-data_start)+(code_end-code_startseg))&15))>>4  ; Paragraph count of minimum required memory.
dw 0xffff  ; Paragraph count of maximum required memory.
dw (code_end-code_startseg)>>4  ; Stack segment (ss) base, will be same as ds. Low 4 bits are in vstart= of .data.
code_startseg:
dw (bss_end-bss_start)+(data_end-data_start) ; Stack pointer (sp).
dw 0  ; No file checksum.
dw code_start-code_startseg  ; Instruction pointer (ip): 8.
dw 0  ; Code segment (cs) base.
; We reuse the final 4 bytes of the .exe header (dw relocation_table_ofs,
; overlay_number) for code.
code_start:
);
$fullprog_data = q(
code_end:
; Fails with `error: TIMES value -... is negative` if code is too large (>~64 KiB).
times -((code_end-code_startseg)>>16) db 0
section .data align=1 vstart=((code_end-code_startseg)&15)
data_start:
);
$fullprog_bss = q(
data_end:
section .bss align=1  ; vstart=0
bss_start:
);
$fullprog_end = q(
auto_stack:  ; Autodetect stack size to fill data segment to 65535 bytes.
resb ((auto_stack-bss_start)+(data_end-data_start))&1  ; Word-align stack, for speed.
auto_stack_aligned:
%define stack_size (65534-((auto_stack_aligned-bss_start)+(data_end-data_start)))
times (stack_size-10)>>256 resb 0  ; Assert that stack size is at least 10.
stack: resb stack_size
bss_end:
; Fails with `error: TIMES value -... is negative` if data is too large (>~64 KiB).
times -(((bss_end-bss_start)+(data_end-data_start))>>16) db 0
);
    } else {  # .com
# Based on https://github.com/pts/pts-nasm-fullprog/blob/master/fullprog_dosexe.inc.nasm
$fullprog_code = q(
section .text align=1 vstart=0x100  ; org 0x100
code_start:
);
$fullprog_data = q(
code_end:
; Fails with `error: TIMES value -... is negative` if code is too large (>~64 KiB).
times -((code_end-code_start+0x100)>>16) db 0
section .data align=1 vstart=0x100+(code_end-code_start)  ; vfollows=.text is off by 2 bytes.
data_start:
);
$fullprog_bss = q(
data_end:
section .bss align=1  ; vstart=0
bss_start:
);
$fullprog_end = q(
auto_stack:  ; Autodetect stack size to fill main segment to almost 65535 bytes.
%define stack_size (65535-3-((auto_stack-bss_start)+(data_end-data_start)+(code_end-code_start+0x100)))
times (stack_size-10)>>256 resb 0  ; Assert that stack size is at least 10.
; This is fake, end of stack depends on DOS, typically sp==0xfffe or sp==0xfffc.
stack: resb stack_size
bss_end:
call__fullprog_end:  ; Make fullprog_code without fullprog_end fail.
; Fails with `error: TIMES value -... is negative` if data is too large (>~64 KiB).
; +3 because some DOS systems set sp to 0xfffc instead of 0xffff
; (http://www.fysnet.net/yourhelp.htm).
times -(((bss_end-bss_start)+(data_end-data_start)+(code_end-code_start+0x100)+3)>>16) db 0
);
    }
    print $exef qq(bits 16\ncpu $nasm_cpu\n);
    print $exef qq($fullprog_code\n);
    print $exef qq(db 0x16  ; push ss\ndb 0x1f  ; pop ds\n) if $is_exe and $is_data_used;
    print $exef qq(cld\n) if $need_clear_df;
    if ($do_clear_bss_with_code) {  # $clear_bss.
      # .com startup: cs=ds=es=ss=PSP, ip=0x100, cs:0x100=first_file_byte.
      # .exe startup: ds=es=PSP, cs+ip+ss+sp are base+from_exe_header.
      print $exef qq(push es\n) if $is_exe and $lf{start_es_psp};
      print $exef qq(push ds\npop es\n) if $is_exe;
      print $exef qq(mov di, bss_start\nmov cx, (stack-bss_start+1)>>1\nxor ax, ax\nrep stosw\n);
      print $exef qq(pop es\n) if $is_exe and $lf{start_es_psp};
    } elsif ($need_clear_ax) {
      print $exef qq(db 0x31, 0xC0  ; xor ax, ax\n  ; argc=0);
    }
    if (defined($text_symbol_ofs{"G\$_start_"})) {  # TODO(pts): Keep these consistent with emit_executable.
      if ($is_exe and $does_entry_point_return) {
        print $exef qq(db 0xE8\ndw 0x0000+G\$_start_-\(\$+2\)  ; call G\$_start_\n);
        print $exef qq(db 0xB8, 0, 0x4C, 0xCD, 0x21  ; mov ax, 0x4c00;; int 0x21  ; EXIT with code 0.\n);
      } elsif ($text_symbol_ofs{"G\$_start_"} == 0) {  # Code starts with _start.
      } else {
        print $exef qq(db 0xE9\ndw 0x0000+G\#_start_-\(\$+2\)  ; jmp strict word G\$_start_\n);
      }
    } elsif (defined($text_symbol_ofs{"G\$main_"}) and $do_use_argc) {
      # OpenWatcom wcc does not support non-constant initializers, so we can call
      # main now.
      print $exef qq(xor dx, dx\ncall G\$main_\nmov ah, 0x4c  ; dx: argv=NULL; EXIT, exit code in al\nint 0x21\n);
    } elsif (defined($text_symbol_ofs{"G\$main_"})) {
      print $exef qq(call G\$main_\nmov ah, 0x4c  ; EXIT, exit code in al\nint 0x21\n);
    }
    for my $segment_name (@SEGMENT_ORDER) {
      print $exef qq($fullprog_data\n) if $segment_name eq "CONST";  # Double-quoted string literals.
      print $exef qq($fullprog_bss\n) if $segment_name eq "_BSS";
      emit_nasm_segment($segment_name, $exef, $segment_sizes{$segment_name}, $ledata{$segment_name}, $segment_symbols{$segment_name}, $fixupp{$segment_name});
    }
    print $exef qq($fullprog_end\n);
  } else {  # emit_executable.
    my $init_regs = "";
    $init_regs .= "\x16\x1F" if $is_exe and $is_data_used;  # push ss; pop ds
    $init_regs .= "\xFC" if $need_clear_df;  # String instructions (e.g. movsb, stosw) need df=0 (cld).
    # !! In wcc ABI, we can ruin es, so don't save+restore it.
    my $clear_bss = $do_clear_bss_with_code ? (
        "\x06" x !(!($is_exe and $lf{start_es_psp})) .  # push es
        "\x1E\x07" x !(!($is_exe)) .  # push ds;; pop es
        pack("a1va1va4", "\xBF", 0, "\xB9", ($segment_sizes{_BSS} + 1) >> 1, "\x31\xC0\xF3\xAB") .  # Affected by fixups below. mov di, bss_start;; mov cx, (stack-bss_start+1)>>1;; xor ax, ax;; rep stosw
        "\x07" x !(!($is_exe and $lf{start_es_psp}))) :  # pop es
        $need_clear_ax ? "\x31\xC0" : "";  # xor ax, ax  ; argc=0.
    # $call_main is affected by fixups below.
    my($call_main, $call_main_symbol, $call_main_ofs);
    if (defined($text_symbol_ofs{"G\$_start_"})) {
      if ($is_exe and $does_entry_point_return) {
        # call _start_;; mov ax, 0x4c00;; int 0x21  ; EXIT with code 0.
        $call_main = pack("ava5", "\xE8", 0, "\xB8\x00\x4C\xCD\x21");
        $call_main_symbol = "G\$_start_"; $call_main_ofs = length($call_main) - 7;
      } elsif ($text_symbol_ofs{"G\$_start_"} == 0) {  # Code starts with _start.
        $call_main = ""; $call_main_symbol = $call_main_ofs = undef;
      } else {
        # !! TODO(pts): Instead of the jmp, move the code of $clear_bss and $call_main just above _start.
        $call_main = pack("a1v", "\xE9", 0);  # jmp strict word _start_
        $call_main_symbol = "G\$_start_"; $call_main_ofs = length($call_main) - 2;
      }
    } elsif (defined($text_symbol_ofs{"G\$main_"}) and $do_use_argc) {
      # OpenWatcom wcc does not support non-constant initializers, so we can call
      # main now.
      # xor dx, dx;; call G$main_;; mov ah, 0x4c;; int 0x21  ; dx: argv=NULL; EXIT, exit code in al
      $call_main = pack("a3va4", "\x31\xD2\xE8", 0, "\xB4\x4C\xCD\x21");
      $call_main_symbol = "G\$main_"; $call_main_ofs = length($call_main) - 6;
    } elsif (defined($text_symbol_ofs{"G\$main_"})) {
      # call main_;; mov ah, 0x4c;; int 0x21  ; EXIT, exit code in al
      $call_main = pack("a1va4", "\xE8", 0, "\xB4\x4C\xCD\x21");
      $call_main_symbol = "G\$main_"; $call_main_ofs = length($call_main) - 6;
    }
    my $vofs = ($is_exe ? 8 : 0x100) + length($init_regs) + length($clear_bss);
    my %segment_vofs;
    $segment_vofs{call_main} = $vofs; $vofs += length($call_main);  # For the relocation below.
    $segment_vofs{_TEXT} = $vofs; $vofs += length($ledata{_TEXT});
    my $after_text_vofs = $vofs;
    $vofs &= 15 if $is_exe;
    my $dgroup_vofs = $segment_vofs{CONST} = $vofs; $vofs += length($ledata{CONST});
    $segment_vofs{CONST2} = $vofs; $vofs += length($ledata{CONST2});
    $segment_vofs{_DATA} = $vofs; $vofs += length($ledata{_DATA});
    $segment_vofs{_BSS} = $vofs; $vofs += $segment_sizes{_BSS};
    my %symbol_vofs;  # $symbol => $vofs + $obj_ofs.
    for my $segment_name (keys %segment_symbols) {
      my $this_segment_vofs = $segment_vofs{$segment_name};
      $symbol_vofs{"S\$${segment_name}"} = $this_segment_vofs;
      for my $pair (@{$segment_symbols{$segment_name}}) {
        my($ofs, $symbol) = @$pair;
        $symbol_vofs{$symbol} = $this_segment_vofs + $ofs;
      }
    }
    my $data_size = $segment_sizes{CONST} + $segment_sizes{CONST2} + $segment_sizes{_DATA};
    die "$0: fatal: data too large\n" if $data_size + $segment_sizes{_BSS} > 65535;  # !! Allow 65536, also in nasm.
    die "$0: fatal: code too large\n" if $after_text_vofs > 65535;  # !! Allow 65536, also in nasm.
    die "$0: fatal: code+data too large for .com\n" if !$is_exe and $vofs > 65535;
    my $stack_align_size = ($data_size + $segment_sizes{_BSS}) & 1;
    my $stack_size = 65535 - (($data_size + $segment_sizes{_BSS} + ($is_exe ? 0 : 2 + $after_text_vofs) + 1) | 1);
    die "$0: fatal: stack too small (code and data too large)\n" if $stack_size < 10;
    die "$0: assert: bad stack size\n"  if $is_exe and $data_size + $segment_sizes{_BSS} + $stack_align_size + $stack_size != 65534;
    if ($is_exe) {
      my $image_size = 24 + length($init_regs) + length($clear_bss) + length($call_main) + $segment_sizes{_TEXT} + $data_size;
      my $exe_header = pack("a2v11", "MZ", $image_size & 511, ($image_size + 511) >> 9, 0, 1,
          ($segment_sizes{_BSS} + $stack_align_size + $stack_size + 15-(-($data_size + $after_text_vofs) & 15)) >> 4,
          0xffff, $after_text_vofs >> 4, $data_size + $segment_sizes{_BSS} + $stack_align_size + $stack_size, 0, 8, 0);
      print $exef $exe_header;
    }
    substr($clear_bss, 1 + ($is_exe ? 2 : 0) + (($is_exe and $lf{start_es_psp}) ? 1 : 0), 2) = pack("v", $segment_vofs{_BSS}) if length($clear_bss) >= 6;
    if (defined $call_main_ofs) {
      die "$0: assert: unknown entry point: $call_main_symbol\n" if !defined($symbol_vofs{$call_main_symbol});
      substr($call_main, $call_main_ofs, 2) = pack("v", $symbol_vofs{$call_main_symbol} - ($call_main_ofs + 2 + $segment_vofs{call_main}));
    }
    # Tiny version of
    # https://github.com/open-watcom/open-watcom-v2/blob/master/bld/clib/startup/a/cstrt086.asm
    print $exef $init_regs, $clear_bss, $call_main;
    for my $segment_name (@SEGMENT_ORDER) {
      my $data = $ledata{$segment_name};
      my $this_segment_vofs = $segment_vofs{$segment_name};
      for my $fixup (@{$fixupp{$segment_name}}) {  # Apply fixups.
        my($endofs, $ofs, $ltypem, $symbol) = @$fixup;
        die "$0: assert: bad endofs in fixup\n" if $endofs > length($data);
        die "$0: assert: unknown symbol in fixup: $symbol\n" if !defined($symbol_vofs{$symbol});
        my $svofs = $symbol_vofs{$symbol} + unpack("v", substr($data, $ofs, 2));
        #printf STDERR "info: fixup \@0x%04x base=0x%04x symbol=%s add=0x%04x is_rel=%d\n", $ofs, unpack("v", substr($data, $ofs, 2)), $symbol, $symbol_vofs{$symbol}, ($ltypem < 0 or 0);
        $svofs -= $endofs + $this_segment_vofs if $ltypem < 0;
        substr($data, $ofs, 2) = pack("v", $svofs);
      }
      print $exef $data;
    }
  }
  };  # End of eval block.
  close($exef) if $exef;
  if ($@) { print STDERR $@; exit(4 + $is_nasm); }
}

# --- End of linker, main code continues.

# --- Perl script runner.

sub fix_path() {
  if ($is_win32) {
    $ENV{PATH} = "" if !defined($ENV{PATH}) or !length($ENV{PATH});
    die "$0: assert: bad directory for \$ENV{PATH}: $MYDIR\n" if
        $MYDIR =~ y@"@@;
    # !! TODO(pts): Verify quoting with space and with ; in $MYDIR.
    my $mydirq = $MYDIR =~ y@;@@ ? qq("$MYDIR") : $MYDIR;
    $ENV{PATH} = "$mydirq;$ENV{PATH}";
  } else {
    $ENV{PATH} = "/bin:/usr/bin" if !defined($ENV{PATH}) or !length($ENV{PATH});
    die "$0: assert: bad directory for \$ENV{PATH}: $MYDIR\n" if
        $MYDIR =~ y@:@@;
    $ENV{PATH} = "$MYDIR:$ENV{PATH}";
  }
}

sub find_perl_script($;$) {
  my ($script, $is_dir_ok) = @_;
  # Only find explicitly specified directories, don't try $MYDIR.
  if ($is_dir_ok and -d($script)) { return \$script }
  # Don't try . if not explicitly specified, there may be a malicious script
  # lying around in the source tree.
  my $extdir;
  my @prefixes = $script =~ m@\A(?:[.]/|[.][.]/|[/])@ ? ("") :  # TODO(pts): Port this to Win32.
      (defined($extdir = $ENV{DOSMCEXT}) and length($extdir)) ? ("$extdir/") : ("$MYDIR/");
  for my $prefix (@prefixes) {
    my $fn = $prefix . $script;
    if (-f($fn)) { return $fn }
    #if ($is_dir_ok and -d(_)) { return \$fn }
    $fn .= ".pl"; if (-f($fn)) { return $fn }
  }
  die "$0: fatal: Perl script not found: $script\n";
}

# Can be called multiple times, result will be idempotent (on @INC etc.).
# $_[0] is the final script filename, rest of @_ is @ARGV to pass.
sub run_found_perl_script {
  my $script = shift(@_);
  die "$0: fatal: Perl script not found: $script\n" if !-f($script);
  my $script_dir = $script; die "$0: assert: script_dir\n" if $script_dir !~ s@/+[^/]+\Z(?!\n)@@;  # TODO(pts): Port this to Win32.
  my @old_argv = @ARGV; my @old_inc = @INC; my $old_path = $ENV{PATH};
  @ARGV = @_;
  unshift @INC, $script_dir, $MYDIR;  # Don't add ".", the script can add it if needed.
  $ENV{PATH} = "$script_dir:$MYDIR:$ENV{PATH}";
  my $result;
  { local $0 = $script; $result = do($script); @ARGV = @old_argv; @INC = @old_inc; $ENV{PATH} = $old_path; die $@ if $@; }
  die "$0: fatal: running Perl script $script: $!\n" if !defined($result) and $!;
  $result
}

# Can be called multiple times, result will be idempotent (on @INC etc.).
# $_[0] is script filename (before autodetection), rest of @_ is @ARGV to pass.
sub run_perl_script {
  unshift @_, find_perl_script(shift(@_));
  goto &run_found_perl_script;
}

# Can be called multiple times, result will be idempotent (on @INC etc.).
# $_[0] is script filename (before autodetection) or name of the directory
# containing dosmcdir.pl, rest of @_ is @ARGV to pass.
sub run_perl_script_or_dir {
  my $script = find_perl_script(shift(@_), 1);
  if (ref $script) {  # Found directory.
    $script = $$script;
    $script =~ s@/+.(?=/)@@g; $script =~ s@/+[.]\Z(?!\n)@@;
    my $count = 16; my $pre_script = $script; my $try_script;
    for (my $count = 32; $count > 0; --$count) {
      $try_script = "$pre_script/dosmcdir.pl";
      last if -f($try_script);
      $try_script = undef; $pre_script .= "/..";  # TODO(pts): Port this to Win32.
    }
    die "$0: fatal: no Perl script dosmcdir.pl found up from: $script\n" if !defined($try_script);
    unshift @_, $try_script, $script;
  } else {
    unshift @_, $script;
  }
  goto &run_found_perl_script;
}

# TODO(pts): Port this to Win32.
if (@ARGV and $ARGV[0] !~ m@\A-@ and ($ARGV[0] =~ m@[.]p[lm]\Z(?!\n)@i or $ARGV[0] !~ m@[.][^./]+\Z(?!\n)@)) {
  fix_path();
  run_perl_script_or_dir(@ARGV); exit;
}

# --- Compiler frontend (calls compiler, assembler and (embedded) linker).

my $ARG = "";
my $EXT = "";
my $EXEOUT = "";
my $Q = "-q";
my $PL = "-ce";
my $CPUF = "-0";
my @sources;
my @wcc_args;
my @defines;
my $do_add_libc = 1;
my $is_first_arg = 1;

for my $arg (@ARGV) {
  if ($arg eq "--" or $arg eq "-" or !length($arg)) {
    die "$0: fatal: unsupported argument: $arg\n";
  } elsif ($arg eq "-pl" or  # Do preprocessing only (also wcc).
           $arg eq "-zs" or  # Do syntax check only (also wcc).
           $arg eq "-c" or  # Compile to .obj files, don't link (hardcoded to wcc, also wcl).
           $arg eq "-ce" or  # Compile and link to executable (.com or .exe) directly (default, no wcc, no wcl).
           $arg eq "-cn" or  # Compile and link to executable (.com or .exe) using nasm while linking (no wcc, no wcl).
           $arg eq "-cl" or  # Compile and build static library (.lib) from the .obj files.
           $arg eq "-cw") {  # Compile to .wasm files, don't link (no wcc, no wcl). .wasm output can be used next time instead of .obj (-c), except that the entry point is omitted (i.e. wdis emits `END' instead of `END ...').
    $PL = $arg;
    $EXT = "lib" if $arg eq "-cl";
  } elsif ($arg eq "-q") {
    $Q = $arg;  # Quiet. Default.
  } elsif ($arg eq "-nq") {  # No such flag in wcc or wcl.
    $Q = "";
  } elsif ($arg eq "-bt=dos" or $arg eq "-bt=exe") {
    $EXT = "exe";  # Default.
  } elsif ($arg eq "-bt=com" or $arg eq "-mt") {
    $EXT = "com";
  } elsif ($arg eq "-bt=bin" or $arg eq "-mb") {  # No such flag value in wcc or wcl.
    $EXT = "bin";
  } elsif ($arg =~ m@\A-bt@) {
    die"$0: fatal: unsupported target: $arg\n";
  } elsif ($arg =~ m@\A-(?:fo|fe)=(.*)\Z(?!\n)@s) {
    $EXEOUT = $1;  # `wcc -fo=...' for object files; `wcl -fe=...' for executable files. For dosmc, it's final output file.
  } elsif ($arg eq "-ms") {
  } elsif ($arg =~ m@\A-m@) {
    die "$0: fatal: only -ms (small memory model) supported: $arg\n";
  } elsif ($arg =~ m@\A-[0-6]\Z(?!\n)@) {
    $CPUF = $arg;
  } elsif ($arg =~ m@\A-(?:b|zW|zw)@) {
    die "$0: fatal: unsupported Windows target: $arg\n";
  } elsif ($arg eq "-ecw") {  # We support only the Watcom default calling convention (and name mangling).
  } elsif ($arg =~ m@\A-ec@) {
    die "$0: fatal: unsupported default calling convention: $arg\n";
  } elsif ($arg =~ m@\A-[DU]@) {
    push @defines, $arg;
  } elsif ($arg eq "-nl") {  # wcc and wcl doesn't support this flag.
    $do_add_libc = 0;
  } elsif ($arg =~ m@\A-@) {
    push @wcc_args, $arg;
  } elsif ($is_first_arg and -d($arg)) {
    # To disable this (arbitrary Perl script execution by directory name),
    # pass -q (or any other flag) as 1st arg.
    fix_path();
    run_perl_script_or_dir(@ARGV); exit;
  } elsif ($arg =~ m@[.](c|nasm|wasm|asm|obj|lib)\Z(?!\n)@) {
    push @sources, $arg;
  } else {
    die "$0: fatal: unknown file extension for source file (must be .c, .nasm, .wasm, .asm, .obj or .lib): $arg\n";
  }
  $is_first_arg = 0;
}
$EXT = $EXEOUT =~ m@[.](?:com|COM)\Z(?!\n)@ ? "com" : "exe" if !length($EXT);
die "$0: fatal: missing source file argument\n" if !@sources;
for my $srcfn (@sources) {
  die "$0: fatal: source file not found: $srcfn\n" if !-f($srcfn);
}
my $is_multiple_sources_ok = 0;

if (!-x("$MYDIR/wcc$tool_exe_ext")) {
  my $download_script_fn = $is_win32 ? "download_win32exec.sh" : $^O =~ m@linux@i ? "download_linuxi386exec.sh" : undef;
  die "$0: fatal: missing executable $MYDIR/wcc$tool_exe_ext -- is your host system supported?\n" if !defined($download_script_fn);
  die "$0: fatal: missing executable $MYDIR/wcc$tool_exe_ext; run $MYDIR/../$download_script_fn first\n";
}
my $in1base = $sources[0]; $in1base =~ s@[.][^./]+\Z(?!\n)@@s;  # TODO(pts): Port to Win32.
my $PLL = "";
die "$0: fatal: output mode incompatible -bt=bin: $PL\n" if
    $EXT eq "bin" and !($PL eq "-ce" or $PL eq "-cn" or $PL eq "-cl" or $PL eq "-pl");
if ($PL eq "-cn" or $PL eq "-ce" or $PL eq "-cl") {
  if ($EXT eq "bin") {
    $is_multiple_sources_ok = 1 if !length($EXEOUT);
    $PL = "-bt=bin" if !$is_multiple_sources_ok;  # For error message below.
  } else {
    $EXEOUT = "$in1base.$EXT" if !length($EXEOUT) and $EXT ne "bin";
    $is_multiple_sources_ok = 1;
  }
} elsif ($PL eq "-cw") {
  $EXEOUT = "$in1base.wasm" if !length($EXEOUT);
} else {
  if ($PL eq "-c") {
    $is_multiple_sources_ok = 1 if !length($EXEOUT);
  } else {
    $PLL = $PL;
    $is_multiple_sources_ok = 1 if $PL eq "-zs";
    push @wcc_args, "-fo=$EXEOUT" if length($EXEOUT);
  }
}
die "$0: fatal: multiple source file arguments with $PL\n" if !$is_multiple_sources_ok and @sources > 1;

delete $ENV{WATCOM};
delete $ENV{INCLUDE};
fix_path();

# Quote string from Bourne-like shells.
sub shqe($) {
  return $_[0] if $_[0]=~/\A[-.\/\w][-.\/\w=]*\Z(?!\n)/;
  my $s = $_[0];
  if ($is_win32) {
    die "$0: fatal: unsupported shell argument: $s\n" if $s =~ y@"@@;
    qq("$s")
  } else {
    $s = ~s@'@'\\''@g;
    "'$s'"
  }
}

sub print_command(@) {
  my $redirect = "";
  $redirect .= " >" . shqe(substr(pop(@_), 3)) if @_ and substr($_[-1], 0, 3) eq " > ";
  my $cmdstr = join(" ", map { shqe($_) } @_);
  select(STDOUT); $| = 1; print ": $cmdstr$redirect\n";
}

sub run_command(@) {
  print_command(@_) if !length($Q);
  if (substr($_[-1], 0, 3) eq " > ") {  # Redirect stdout.
    die "$0: assert: command too short\n" if @_ < 2;  # 2 for shell word splitting.
    my $fn = substr(pop(@_), 3);
    my $f;
    die "$0: fatal: cannot open for writing: redirect stdout\n" if !open($f, ">", $fn);
    binmode($f);
    # !! TODO(pts): Port to Win32. Where do we need binmode?
    my $old_stdoutf;
    die "$0: fatal: cannot redirect old stdout\n" if !open($old_stdoutf, ">&", \*STDOUT);
    die "$0: fatal: cannot redirect stdout\n" if !open(STDOUT, ">&", $f);
    close($f);
    my $status = system(@_);
    die "$0: fatal: cannot redirect back stdout\n" if !open(STDOUT, ">&", $old_stdoutf);
    close($old_stdoutf);
    $status
  } else {
    die "$0: assert: command too short\n" if @_ < 2;  # 2 for shell word splitting.
    system(@_)  # Returns 0 on success.
  }
}

# Detects assembly language, returns "wasm" or "nasm".
sub detect_asm($) {
  my $asmfn = $ARGV[0];
  my $f;
  die "$0: fatal: cannot open .asm file for reading: $asmfn\n" if !open($f, "<", $asmfn);
  binmode($f);  # Would also work without it, but be deterministc.
  local $_;
  while (<$f>) {
    s@\A\s+@@;
    if (m@\A(?:;|GLOBAL\s+|PUBLIC\s+)@i) {  # Available in both "wasm" and "nasm".
    } elsif (m@\A([.]|EXTRN\s+|\w+\s+(?:GROUP|SEGMENT|MACRO|=)\s+)@i) {
      close($f); return "wasm";
    } elsif (m@\A(%|ORG\s+|BITS\s+|CPU\s+|EXTERN\s+|GROUP\s+|SEGMENT\s+|SECTION\s+TIMES\s+|__LINKER_FLAG\()@i) {
      close($f); return "nasm";
    } elsif (y@\r\n@@c) {
      last  # Unable to parse first line.
    }
  }
  close($f);
  # To force "wasm", start the file with `WASM MACRO', then in next line: `ENDM'.
  # To force "nasm", start the file with `%define NASM'.
  die "$0: fatal: cannot detect .asm file syntax: $asmfn\n";
}

my $NASM_OBJ_HEADER = q(
;uppercase  ; Would also convert labels to uppercase.
%macro org 1  ; .com file source emulation.
%if %1!=256
%error expecting org 0x100 for compatibility with .com file sources
times -1 db 0
%endif
__LINKER_FLAG(omit_cld)
__LINKER_FLAG(uninitialized_bss)
__LINKER_FLAG(start_es_psp)
; Do not allow any other entry point.
..start:
_start_:
%endmacro
global _start_
%define __LINKER_FLAG(name) extern __linker_flag_ %+ name
segment _TEXT class=TEXT align=1  ; Make it the last one (default).
segment _BSS class=BSS align=1
segment _DATA class=DATA align=1
segment CONST class=DATA align=1
segment CONST2 class=DATA align=1
;segment STACK class=STACK align=2
segment _TEXT  ; Select default.

; The purpose of this magic (of redefining `segment' and `section') is to
; canonicalize segment names to those which wcc generates, and slo to avoid
; the NASM warning `warning: segment attributes specified on redeclaration
; of segment: ignoring' when `segment .bss align=1' is present in the .nasm
; file (it will be transformed to just `segment .bss', which prevents the
; warning).
%define segment __OBJ_SEGMENT__
%define section __OBJ_SEGMENT__
%define SEGMENT __OBJ_SEGMENT__  ; FYI In NASM 0.99.06 .. 2.14.02, this still produces an error for mixed-case segMent etc.: error: unrecognised directive [__OBJ_SEGMENT__]
%define SECTION __OBJ_SEGMENT__
%macro __OBJ_SEGMENT__ 1
%undef __SEGTRY_unchanged
%undef __SEGTRY_.text
%undef __SEGTRY_.TEXT
%undef __SEGTRY__text
%undef __SEGTRY__TEXT
%undef __SEGTRY_text
%undef __SEGTRY_TEXT
%undef __SEGTRY_.code
%undef __SEGTRY_.CODE
%undef __SEGTRY__code
%undef __SEGTRY__CODE
%undef __SEGTRY_code
%undef __SEGTRY_CODE
%undef __SEGTRY_.bss
%undef __SEGTRY_.BSS
%undef __SEGTRY__bss
%undef __SEGTRY__BSS
%undef __SEGTRY_bss
%undef __SEGTRY_BSS
%undef __SEGTRY_.stack
%undef __SEGTRY_.STACK
%undef __SEGTRY__stack
%undef __SEGTRY__STACK
%undef __SEGTRY_stack
%undef __SEGTRY_STACK
%undef __SEGTRY_.data
%undef __SEGTRY_.DATA
%undef __SEGTRY__data
%undef __SEGTRY__DATA
%undef __SEGTRY_data
%undef __SEGTRY_DATA
%undef __SEGTRY_.const
%undef __SEGTRY_.CONST
%undef __SEGTRY__const
%undef __SEGTRY__CONST
%undef __SEGTRY_const
%undef __SEGTRY_CONST
%undef __SEGTRY_.const2
%undef __SEGTRY_.CONST2
%undef __SEGTRY__const2
%undef __SEGTRY__CONST2
%undef __SEGTRY_const2
%undef __SEGTRY_CONST2
%define __SEGTRY_%1  ; Ignores everything after the first whitespace in %1.
%undef  segment
%define segment segment  ; Use original meaning of the segment directive below to select segment.
%ifdef __SEGTRY_unchanged
%elifdef __SEGTRY_.text
segment _TEXT
%elifdef __SEGTRY_.TEXT
segment _TEXT
%elifdef __SEGTRY__text
segment _TEXT
%elifdef __SEGTRY__TEXT
segment _TEXT
%elifdef __SEGTRY_text
segment _TEXT
%elifdef __SEGTRY_TEXT
segment _TEXT
%elifdef __SEGTRY_.code
segment _TEXT
%elifdef __SEGTRY_.CODE
segment _TEXT
%elifdef __SEGTRY__code
segment _TEXT
%elifdef __SEGTRY__CODE
segment _TEXT
%elifdef __SEGTRY_code
segment _TEXT
%elifdef __SEGTRY_CODE
segment _TEXT
%elifdef __SEGTRY_.bss
segment _BSS
%elifdef __SEGTRY_.BSS
segment _BSS
%elifdef __SEGTRY__bss
segment _BSS
%elifdef __SEGTRY__BSS
segment _BSS
%elifdef __SEGTRY_bss
segment _BSS
%elifdef __SEGTRY_BSS
segment _BSS
%elifdef __SEGTRY_.stack
segment STACK
%elifdef __SEGTRY_.STACK
segment STACK
%elifdef __SEGTRY__stack
segment STACK
%elifdef __SEGTRY__STACK
segment STACK
%elifdef __SEGTRY_stack
segment STACK
%elifdef __SEGTRY_STACK
segment STACK
%elifdef __SEGTRY_.data
segment _DATA
%elifdef __SEGTRY_.DATA
segment _DATA
%elifdef __SEGTRY__data
segment _DATA
%elifdef __SEGTRY__DATA
segment _DATA
%elifdef __SEGTRY_data
segment _DATA
%elifdef __SEGTRY_DATA
segment _DATA
%elifdef __SEGTRY_.const
segment CONST
%elifdef __SEGTRY_.CONST
segment CONST
%elifdef __SEGTRY__const
segment CONST
%elifdef __SEGTRY__CONST
segment CONST
%elifdef __SEGTRY_const
segment CONST
%elifdef __SEGTRY_CONST
segment CONST
%elifdef __SEGTRY_.const2
segment CONST2
%elifdef __SEGTRY_.CONST2
segment CONST2
%elifdef __SEGTRY__const2
segment CONST2
%elifdef __SEGTRY__CONST2
segment CONST2
%elifdef __SEGTRY_const2
segment CONST2
%elifdef __SEGTRY_CONST2
segment CONST2
%else
; %1 may also include segment attributes (e.g. class=CODE align=1), which
; %nasm ignores with a warning if called again for the same segment.
segment %1
%endif
%undef  segment
%define segment __OBJ_SEGMENT__
%endmacro

);

# Corresponding `wcc: owcc' flags:
# -v: lack of -q
# -bdos: -bt=dos
# -ms: -mcomodel=s (default)
# -i=... : -I...
# -s: -fno-stack-check
# -os: -Os  TODO(pts): Should we do -om -oi -ol (from -ox) as well?
# -0: -march=i86
# -W: ??
# ??: -W
# -w4: -Wall
# -wx: -Wextra
# -we: -Werror
# -wcd=202: -Wcd=202 ??
# -D...: -D...
# (default to generate obj, do not link): -c
# -fo=...: -o ...
# -fr: ?? Set error filename.
# -pl: -E
# No need to set $WATCOM or to extend $PATH.
# 202: symbol defined but not referenced (useful for static functions).
my $is_bin = $EXT eq "bin";
my @d_args;  # Applies to wcc and nasm.
push @d_args, "-D__DOSMC__";
push @d_args, "-D__DOSMC_COM__" if $EXT eq "com";  # Shouldn't make a difference, identical .obj files work for .exe and .com.
push @d_args, "-D__DOSMC_BIN__" if $is_bin;
push @d_args, @defines;
my @wcc_cmd = ('wcc', @d_args);
push @wcc_cmd, $Q if length($Q);
push @wcc_cmd, $PLL if length($PLL);
push @wcc_cmd, "-bt=dos", "-ms", "-i=$MYDIR", "-s", "-os", "-W", "-w4", "-wx", "-we", "-wcd=202", $CPUF, "-fr", @wcc_args;
my $wcc_cmd_size = @wcc_cmd;
my @wasm_cmd = ('wasm', @d_args);
push @wasm_cmd, $Q if length($Q);
push @wasm_cmd, "-ms", "-i=$MYDIR", $CPUF;
my $wasm_cmd_size = @wasm_cmd;
my $nasm_cpu = $CPUF eq "-0" ? "8086" : substr($CPUF, 1) . "86";
# TODO(pts): Copy some flags from @ARGV, pass as @nasm_flags here.
my @nasm_cmd = ("nasm", @d_args, "-O9", "-f", $is_bin ? "bin" : "obj", "-w+orphan-labels");  # Default is `bits 16'.
my $nasm_cmd_size = @nasm_cmd;
my @objfns;
my $do_objfn_arg = ($PL eq "-cw" or $PL eq "-ce" or $PL eq "-cn" or $PL eq "-cl" or $PL eq "-c");
my $forced_objfn = (($is_bin or ($PL ne "-cw" and $PL ne "-ce" and $PL ne "-cn" and $PL ne "-cl")) and length($EXEOUT)) ? $EXEOUT : undef;
for my $srcfn (@sources) {
  my $srcbase = $srcfn;
  my $ext = $srcbase =~ s@[.]([^./]+)\Z(?!\n)@@s ? $1 : "";  # TODO(pts): Port to Win32.
  $ext = detect_asm($srcfn) if $ext eq "asm";
  die "$0: fatal: .$ext source incompatible with -bt=bin: $srcfn\n" if $is_bin and $ext ne "nasm";
  if ($ext eq "obj" or $ext eq "lib") { push @objfns, $srcfn; next }
  my $objfn = defined($forced_objfn) ? $forced_objfn : $is_bin ? "$srcbase.bin" : $PL eq "-c" ? "$srcbase.obj" : "$srcbase.tmp.obj";
  push @objfns, $objfn;
  if ($ext eq "nasm") {
    die "$0: fatal: $PL with .nasm source not supported: $srcfn\n" if !$do_objfn_arg and $PL ne "-pl";
    # We predeclare something in $tmpfn. Only NASM >= 2.14 has the --before
    # flag to avoid this.
    my $tmpfn = "$srcbase.inc.tmp.nasm";
    my $tmpf;
    die "$0: fatal: cannot open for writing: $tmpfn\n" if !open($tmpf, ">", $tmpfn);
    binmode($tmpf);
    my $srcfnq = $srcfn;
    $srcfnq =~ s@([\x00-\x1F\\\$"\x7F-\xFF])@ "\\x" . pack("H", $1) @ge;
    my $nasm_header = $is_bin ? "" : $NASM_OBJ_HEADER;
    # TODO(pts): Port to Win32 with \ in the filename.
    die "$0: fatal: cannot write to: $tmpfn\n" if !print($tmpf
        qq(bits 16\ncpu $nasm_cpu\n$nasm_header%include "$srcfnq"\n));
    die "$0: fatal: cannot close: $tmpfn\n" if !close($tmpf);
    if ($PL eq "-pl") {
      push @nasm_cmd, "-E", $tmpfn;
    } else {
      push @nasm_cmd, "-o", $objfn, $tmpfn;
    }
    if (run_command(@nasm_cmd)) {
      print STDERR "$0: fatal: nasm failed\n"; exit(3);
    }
    splice @nasm_cmd, $nasm_cmd_size;
  } elsif ($ext eq "wasm") {
    push @wasm_cmd, "-fo=$objfn" if $do_objfn_arg;
    push @wasm_cmd, $srcfn;
    if (run_command(@wasm_cmd)) {
      print STDERR "$0: fatal: wasm failed\n"; exit(2);
    }
    splice @wasm_cmd, $wasm_cmd_size;
  } else {
    if ($do_objfn_arg) {
      push @wcc_cmd, "-fo=$objfn";
      $wcc_cmd[-1] =~ y@/@\\@ if $is_win32;  # !! Do it more.
    }
    push @wcc_cmd, $srcfn;
    $wcc_cmd[-1] =~ y@/@\\@ if $is_win32;  # !! Do it more.
    if (run_command(@wcc_cmd)) {
      print STDERR "$0: fatal: wcc failed\n"; exit(2);
    }
    splice @wcc_cmd, $wcc_cmd_size;
  }
}

if ($is_bin) {
} elsif ($PL eq "-ce" or $PL eq "-cn") {
  if ($do_add_libc and @objfns) {
    push @objfns, "$MYDIR/dosmc.lib";
    pop @objfns if !-f($objfns[-1]);
  }
  my $is_nasm = $PL eq "-cn" ? 1 : 0;
  my $exefn = $is_nasm ? "$in1base.tmp.nasm" : $EXEOUT;
  print_command("//link", "-bt=$EXT", $CPUF, ($is_nasm ? "-cn" : "-ce"),  "-fe=$exefn", @objfns) if !length($Q);
  link_executable($is_nasm,  $exefn, $EXT, $nasm_cpu, @objfns);
  # .nasm output ($EXEFN) cannot be used to produce an .obj file again (i.e. nasm -f obj).
  # TODO(pts): Add support for this, preferably autodetection.
  if ($is_nasm and run_command("nasm", "-f", "bin", "-o", $EXEOUT, $exefn)) {
    print STDERR "$0: fatal: nasm failed\n"; exit(6);
  }
} elsif ($PL eq "-cl") {
  print_command("//ar", "-fe=$EXEOUT", @objfns) if !length($Q);
  build_static_library($EXEOUT, @objfns);
} elsif ($PL eq "-cw") {
  # Output of wdis ($EXEOUT) can be fed to wasm again to produce an .obj file.
  if (run_command("wdis", "-a", "-fi", "-i=\@", $objfns[0], " > $EXEOUT")) {
    print STDERR "$0: fatal: wdis failed\n"; exit(7);
  }
}

print ": $0 OK.\n" if !length($Q);