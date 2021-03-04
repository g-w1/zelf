; hello.asm

%define stdin       0
%define stdout      1
%define stderr      2
%define SYS_exit    60
%define SYS_write   4

%macro  system      1
        mov         rax, %1
        syscall
%endmacro

%macro  sys.exit    0
        system      SYS_exit
%endmacro

%macro  sys.write   0
        system      SYS_write
%endmacro

section  .data
    hello   db      'Hello, World!', 0Ah
    hbytes  equ     $-hello
section .bss
    symbol resb 0x100
    

section .text
global  _start
_start:
    mov         rdi, stdout
    mov         rsi, hello
    mov         rdx, hbytes
    mov         qword [symbol], 0xefbe
    sys.write

    xor         rdi,rdi
    sys.exit
