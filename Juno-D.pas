program Juno_D;
{Dynamikkorrektur schwarze und wei�e Tasten Juno-D wegen umgebauter Tastatur}
{Drehschalter f�r Roland Scale Tune Messages}

{$NOSHADOW}
{$TYPEDCONST OFF}
{$W+ Warnings}            {Warnings on/off}

{Defines aktivieren durch Entfernen des 1. Leerzeichens!}

{ $DEFINE TEST_MIDI}
{ $DEFINE TEST_STUNE}
{ $DEFINE DEBUG_OUT}  {sends debug messages to serial (observe in simulator)}
{ $DEFINE DYNAMIK_KORREKTUR }

{$IFDEF TEST_MIDI OR TEST_STUNE}
  {$DEFINE DO_TESTS}
{$ENDIF}


Device = mega8, VCC = 5;

Import SysTick, SerPort;

Define
  ProcClock      = 16000000;        {Hertz}
  SysTick        = 1;               {msec}
  StackSize      = $0060, iData;
  FrameSize      = $0040, iData;
  SerPort        = 31250, Stop2;    {Baud, StopBits|Parity}
  RxBuffer       = 16, iData;
  TxBuffer       = 16, iData;

Implementation

{--------------------------------------------------------------}
{ Type Declarations }
{ In Pascal m�ssen Prozedurparameter zuvor definierte Typen haben! }
type Array12 = array [0..11] of integer;

{--------------------------------------------------------------}
{ Const Declarations }
const
{ Keyboard-Interface, Taster und LEDs PortBits }

  LEDOutPort                 = @PortD;
  DDRDinit                   = %00000100;            {PortD Richtung}
  PortDinit                  = %11111100;            {PortD Startwerte}
{$IFDEF DYNAMIK_KORREKTUR}
  { 3 schwarze Tasten in der Dynamik abschw�chen }
  DynMap_0_2_4 : Table[0..127] of byte = (
    {$I 120_90.CSV}
  );
  { 2 weisse Tasten in der Dynamik anheben }
  DynMap_1_3 : Table[0..127] of byte = (
    {$I 70_100.CSV}
  );
{$ENDIF}
{
                         9  >  4  >  B  >  6
                         ^     ^     ^     ^
                         5  >  0  >  7  >  2
                         ^     ^     ^     ^
                         1  >  8  >  3  >  A
}
  clean_cent:      Array12 = (0,12,4,16,-14,-2,-10,2,14,-16,18,-12);

  meantone_cent:   Array12 = (0,16,-6,10,-13,3,-19,-3,13,-10,6,-16);

{ Scale Tune }
  MIN_STUNE     = $00; { GS scale tune min. -64 cent }
  MAX_STUNE     = $7F; { GS scale tune max. +63 cent }
  MEAN_STUNE    = $40; { GS scale tune chromatic }

  SYS_EX        = $F0; { system exclusive transmit F0 }
  SYS_EX_NT     = $F7; { system exclusive not transmit F0 }
  SYS_EX_END    = $F7; { end of system exclusive data }

  ROLAND        = $41;
  BROADCAST_DEV = $7F; { broadcast device }
  GS_MODEL_ID   = $42;
  DATA_SET_1    = $12;

  STUNE_LENGTH = 22;     { length of sysex scale tune string }
  { non-existing MIDI channel 16 is used for addressing patch data }
  STUNE_PATCH_CHANNEL = 16;

  high                       = 1; { Mit 5.04 Compiler funktionieren true und false nicht mehr => 1 und 0 }
  low                        = 0;

{--------------------------------------------------------------}
{ Var Declarations }

var

{$DATA} {Schnelle Register-Variablen}
  Key   : Byte; {in Scan-Routine gebraucht}
  i, j, k: Byte;
  Rstat, last_note_modulo: Byte;  {letzter Running Status, Letzte Note}
  MdatPending    : Byte;          {Noch zu erwartende MIDI-Datenbytes}
  warte_auf_Tonart, MIDI_wegwerfen: boolean; { HR }
  Drehschalter: byte; // Drehschalterwert (3 Bit)

{$IDATA}  {Langsamere SRAM-Variablen}
  failed: boolean; // assert fehlgeschlagen
  test_out: byte; // ersetzt SerOut w�hrend Test von MIDI Prozedur
  scale_tune_gesendet: boolean; // nur f�r Testzwecke
  {_LEDaux[LEDOutPort, 2]     : bit;} {Bit 2 ist LED, separat} { geht so mit 5.04 Compiler nicht mehr }
   _LEDaux[@PortD, 2]     : bit; {Bit 2 ist LED, separat}

{ Scale Tune }
  stune: Table[0..31] of Byte; { memory for sysex scale tune message }

{--------------------------------------------------------------}
{$IFDEF DEBUG_OUT}
{ output string to serial interface for debugging in simulator }
procedure debug_out(message : string[20]);
var
  len: byte;
begin
  SerOut('*');
  len := Length(message);
  for i := 1 to len do
    SerOut(message[i]);
  endfor;
end;
{$ENDIF}

procedure assertTrue(a: boolean; message: string[15]);
var
  full_message: string[20];
begin
  if not a then
    failed := true;
    full_message := 'FAILED '+message;
    for i := 1 to Length(full_message) do
      SerOut(full_message[i]);
    endfor;
  endif;
end;

procedure assertFalse(a: boolean; message: string[15]);
begin
  assertTrue(not a, message);
end;

procedure assertEquals(a: byte; b: byte; message: string[15]);
begin
  assertTrue(a = b, message);
end;

procedure assertDiffers(a: byte; b: byte; message: string[15]);
begin
  assertTrue(a <> b, message);
end;

{ Berechnet Pr�fsumme f�r Roland Sysex-Nachrichten }
{function Roland_checksum(_begin,_end: byte_pointer): byte;
var
  total, mask: byte;
begin
  total := 0 ;
  mask := $7F ;
  while ( _begin <= _end )do
    total := total + _b@ ;
    _begin := _begin + 1 ;
  endwhile;
  return (($80 - (total and mask)) and mask) ;
end;}
function Roland_checksum: byte;
var
  total, mask: byte;
begin
  total := 0 ;
  mask := $7F ;
  for i := 5 to 19 do
    total := total + stune[i];
  endfor;
  return (($80 - (total and mask)) and mask) ;
end;

procedure scale_tune_send(channel: byte);
begin
  if ( channel < 9 ) then
    stune[6] := $11 + channel ;
  else
    if ( channel > 9 ) then
      stune[6] := $10 + channel ;
    else { channel 9 }
      stune[6] := $10 ;
    endif;
  endif;
  { GS data set 1 messages have 3 byte address }
  stune[STUNE_LENGTH - 2] := Roland_checksum() ;

  {$IFDEF DEBUG_OUT}
  debug_out('scale_tune_send:');
  {$ENDIF}

  for i := 0 to STUNE_LENGTH - 1 do
    SerOut(stune[i]);
  endfor ;
  scale_tune_gesendet := true;
end;

procedure scale_tune_send_all;
var
  channel: byte;
begin
  for channel := 0 to STUNE_PATCH_CHANNEL do
    scale_tune_send(channel) ;
  endfor;
end;

{ transponiert (rotiert) Scale Tune Werte um 1 }
procedure scale_tune_transpose;
var;
  tr: integer;
begin
  k := stune[8+11];
  for j := 0 to 10 do
    stune[8+11-j] := stune[8+11-j-1];
  endfor;
  stune[8] := k ;
end;

{ transponiert Scale Tune Werte um key und sendet }
procedure scale_tune_send_key(key: byte);
begin
  key := key mod 12 ;
  for i := 1 to key do
    scale_tune_transpose;
  endfor;
  scale_tune_send_all;
end;

procedure scale_tune_set_equal(_stune: byte);
begin
  for i := 0 to 11 do
    stune[8+i] := _stune;
  endfor;
end;

{procedure scale_tune_set_equal_cent(cent: integer);
begin
  if (cent < -64) then
    cent := -64 ;
  endif;
  if (cent > 63) then
    cent := 63 ;
  endif;
  scale_tune_set_equal(byte(cent + MEAN_STUNE)) ;
end;}

procedure scale_tune_init;
begin
  stune[0] := SYS_EX ;
  stune[1] := ROLAND ;
  stune[2] := BROADCAST_DEV ;
  stune[3] := GS_MODEL_ID ;
  stune[4] := DATA_SET_1 ;
  stune[5] := $40 ;       { address MSB is always equal }
  stune[7] := $40 ;       { address LSB is always equal }
  scale_tune_set_equal(MEAN_STUNE);
  stune[STUNE_LENGTH - 1] := SYS_EX_END ;
end;

procedure scale_tune_set_cent(cent: Array12);
  { up to now: 1 data string for all channels together }
begin
  for i := 0 to 11 do
    if (cent[i] < -64) then
      cent[i] := -64 ;
    endif;
    if (cent[i] > 63) then
      cent[i] := 63 ;
    endif;
    stune[8+i] := byte(cent[i] + MEAN_STUNE) ;
  endfor;
end;

{procedure scale_tune_set(_stune: array[0..11] of byte);
begin
  for i := 0 to 11 do
    stune[8+i] := _stune[i];
  endfor;
end;}

//procedure send_local_off;
//begin
//{  for i := 0 to 15 do}
//    i := 0;
//    SerOut(char($b0 + i)); { channel mode message }
//    SerOut(char(122));     { local control }
//    SerOut(char(0));       { off }
//{  endfor ;}
//end;

procedure MIDI(m: Byte);
begin
  // Ein Midi-Byte wurde empfangen und steht in m
  if m >= $80 then // m ist ein Statusbyte
    Rstat:= m;
    case Rstat of
      $80..$9F :
        // Note off/on
        MdatPending:= 2;
        |
      else
        MdatPending:=0;
    endcase;
   else // Datenbyte 0..127
     case MdatPending of
     2 :
       // Notennr. empfangen
       last_note_modulo := m mod 12;
       dec(MdatPending);
       |
     1 :
       // Dynamik empfangen
{$IFDEF DYNAMIK_KORREKTUR}
       case last_note_modulo of
       0,2,4: m := DynMap_0_2_4[m] ;
            |
       1,3  : m := DynMap_1_3[m] ;
            |
       endcase;
{$ENDIF}
       MdatPending:= 2; // running status!
       if warte_auf_Tonart then
         warte_auf_Tonart := false;
         scale_tune_send_key(last_note_modulo);
         _LEDaux := low; // LED on, we have scale tune
         return;
       endif;
       |
    endcase;
  endif;
  if warte_auf_Tonart then
    return;
  endif;
  {$IFDEF DEBUG_OUT}
  debug_out('MIDI:');
  {$ENDIF}
  {$IFDEF DO_TESTS}
  test_out:= m;
  {$ELSE}
  SerOut(m);
  {$ENDIF}
end;

{--------------------------------------------------------------}

function Drehschalter_gedreht : Boolean;
{Liefert true wenn der Drehschalter am Juno-D gedreht wurde, Sample in BtnInPort}
var
  neu: byte;
begin
  { 3 Leitungen kann der 2*6 Drehschalter beeinflussen,
    aber max. 2 davon auf 0 (Masse) ziehen. }
  neu := PinD;
  neu := (neu and %00111000) shr 3;
  if (neu <> Drehschalter) then
    Drehschalter := neu;
    return (true);
  endif;
  return (false);
end;

{--------------------------------------------------------------}

procedure blink(blinks: byte);
begin
{$IFNDEF DO_TESTS}
{mdelay wartet ewig im Simulator}
  for i := 1 to blinks do
    _LEDaux := low;
    mdelay(250);
    _LEDaux := high;
    mdelay(250);
  endfor;
{$ENDIF}
end;

procedure komplex_blink;
begin
  case (Drehschalter) of
    6:
       _LEDaux := low;
       mdelay(100);
       _LEDaux := high;
       mdelay(700);
       |
//    5:
//       _LEDaux := low;
//       mdelay(100);
//       _LEDaux := high;
//       mdelay(100);
//       _LEDaux := low;
//       mdelay(100);
//       _LEDaux := high;
//       mdelay(500);
//       |
    4:
       _LEDaux := low;
       mdelay(100);
       _LEDaux := high;
       mdelay(100);
       _LEDaux := low;
       mdelay(100);
       _LEDaux := high;
       mdelay(100);
       _LEDaux := low;
       mdelay(100);
       _LEDaux := high;
       mdelay(300);
       |
  endcase;
end;

procedure neue_Skala;
begin
    //blink(Drehschalter);
    scale_tune_set_equal(MEAN_STUNE) ; { erstmal gleichschwebend einstellen }
    { je nach Schalterstellung vorbereiten, noch nicht in richtiger Tonart }
    case (Drehschalter) of
    6: warte_auf_Tonart := true;
       scale_tune_set_cent(clean_cent);
       |
//    5: warte_auf_Tonart := true;
//       scale_tune_set_cent(double29_cent);
//       |
    4: warte_auf_Tonart := true;
       scale_tune_set_cent(meantone_cent);
       |
    else
       { gleichschwebend }
       warte_auf_Tonart := false;
       scale_tune_send_all;
       _LEDaux := high;
    endcase;
end;


procedure init;
{nach Reset aufgerufen}
begin
  DDRD:=  DDRDinit;            {PortD dir}
  PortD:= PortDinit;           {PortD}
  TCNT2:= 0;
  TCCR2:= %00001011;           {CTC mode, Prescaler=64}
  TIMSK:= TIMSK OR %10000000;  {OCIE2=1}
  ADMUX:= ADMUX OR %11000000;  {Internal ADC Reference}

  Drehschalter_gedreht;
  failed := false;
  scale_tune_init;
  warte_auf_Tonart:= false;
  blink(2);
  Rstat:= 0;
  MdatPending:= 0;
//  send_local_off; Juno-D versteht kein Local Off
end;

{--------------------------------------------------------------}
{ Main Program }
{$IDATA}

begin
  Init;
  EnableInts;
{$IFDEF DO_TESTS}
  {$IFDEF TEST_MIDI}
  // ------ MIDI forwarding and transformation tests ----------
  MIDI($90); // note on channel 0
  assertEquals($90, test_out, '1');
  MIDI(13); // note
  assertEquals(13, test_out, '2');
  assertEquals(1, last_note_modulo, '3');
  MIDI(60); // dynamic
  assertDiffers(60, test_out, '4'); // must have been transformed
  
  MIDI(14); // note, running status
  assertEquals(14, test_out, '5');
  assertEquals(2, last_note_modulo, '6');
  MIDI(60); // dynamic
  assertDiffers(60, test_out, '7'); // must have been transformed
  
  MIDI($8f); // note off channel 15
  assertEquals($8f, test_out, '8');
  MIDI(0); // note
  assertEquals(0, test_out, '9');
  assertEquals(0, last_note_modulo, '10');
  MIDI(70); // dynamic
  assertDiffers(70, test_out, '11'); // must have been transformed
  
  MIDI($8f); // note off channel 15
  assertEquals($8f, test_out, '8');
  MIDI(0); // note
  assertEquals(0, test_out, '9');
  assertEquals(0, last_note_modulo, '10');
  MIDI(70); // dynamic
  assertDiffers(70, test_out, '11'); // must have been transformed

  MIDI($C0); // non-note status event
  assertEquals($C0, test_out, '12');
  MIDI(22); // data
  assertEquals(22, test_out, '13');
  {$ENDIF}
  {$IFDEF TEST_STUNE}
  // ------ scale tune tests ----------
  Drehschalter := 7; scale_tune_gesendet := false;
  neue_Skala;
  MIDI($90); // note on channel 0
  MIDI(3);   // note
  MIDI(60);  // dynamic
  assertTrue(scale_tune_gesendet, 'S1');
  assertEquals($40, stune[8], 'S1.1');
  assertEquals($40, stune[8+1], 'S1.2'); // gar nichts umgestimmt

  Drehschalter := 6; scale_tune_gesendet := false;
  neue_Skala;
  MIDI($90); MIDI(12); MIDI(60);
  assertTrue(scale_tune_gesendet, 'S2');
  assertEquals($40, stune[8], 'S2.1'); // Tonart 0 => 0 nicht umgestimmt
  assertDiffers($40, stune[8+1], 'S2.2'); // 1 umgestimmt

  Drehschalter := 5; scale_tune_gesendet := false;
  neue_Skala;
  MIDI($90); MIDI(3); MIDI(60);
  assertTrue(scale_tune_gesendet, 'S3');
  assertDiffers($40, stune[8], 'S3.1'); // Tonart 3 => 0 umgestimmt
  assertEquals($40, stune[8+3], 'S3.2'); // 3 nicht umgestimmt

{ Das wird dem E-Lab Kinderspielzeug-Terminalfenster zu viel:
  Drehschalter := 4; scale_tune_gesendet := false;
  neue_Skala;
  MIDI($90); MIDI(4); MIDI(60);
  assertTrue(scale_tune_gesendet, 'S4');
  assertDiffers($40, stune[8], 'S4.1'); // Tonart 4 => 0 umgestimmt
  assertEquals($40, stune[8+3], 'S4.2'); // 3 umgestimmt

  Drehschalter := 3; scale_tune_gesendet := false;
  neue_Skala;
  MIDI($90); MIDI(3); MIDI(60);
  assertTrue(scale_tune_gesendet, 'S5');
  assertEquals($40, stune[8+2], 'S5.1');
  assertEquals($40, stune[8+3], 'S5.2'); // gar nichts umgestimmt

  Drehschalter := 2; scale_tune_gesendet := false;
  neue_Skala;
  MIDI($90); MIDI(3); MIDI(60);
  assertFalse(scale_tune_gesendet, 'S6');

  Drehschalter := 1; scale_tune_gesendet := false;
  neue_Skala;
  MIDI($90); MIDI(3); MIDI(60);
  assertFalse(scale_tune_gesendet, 'S7');
}
  {$ENDIF}
  if not failed then
    SerOut('S');
    SerOut('U');
    SerOut('C');
    SerOut('C');
    SerOut('E');
    SerOut('S');
    SerOut('S');
  endif;
{$ELSE}
  loop
    repeat
      { so lange Daten kommen, werden sie sofort bearbeitet }
      if warte_auf_Tonart then
        {$IFNDEF DO_TESTS}
        {mdelay wartet ewig im Simulator}
        komplex_blink;
        {$ENDIF}
      endif;
      while SerStat do
        MIDI(SerInp);
      endwhile;
    until Drehschalter_gedreht;
    { Entprellen: warten, bis Schalterwert stabil }
    repeat
      mdelay(500);
    until Drehschalter_gedreht = false ;
    neue_Skala; // setzt evtl. warte_auf_Tonart
  endloop;
{$ENDIF}
end Juno_D.

