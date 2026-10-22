{ FPCUnit console runner. Extra option: --data=DIR (default: data). }
program TestRunner;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, consoletestrunner, TestHelpers, TestChecksums, TestParsers,
  TestHL7, TestAlarms, TestGateway;

type
  TBedsideTestRunner = class(TTestRunner)
  protected
    procedure AppendLongOpts; override;
    procedure DoRun; override;
  end;

procedure TBedsideTestRunner.AppendLongOpts;
begin
  inherited AppendLongOpts;
  LongOpts.Add('data:');
end;

procedure TBedsideTestRunner.DoRun;
begin
  if HasOption('data') then
    TestDataDir := GetOptionValue('data');
  inherited DoRun;
end;

var
  App: TBedsideTestRunner;
begin
  DefaultFormat := fPlain;
  DefaultRunAllTests := True;
  App := TBedsideTestRunner.Create(nil);
  App.Initialize;
  App.Title := 'bedside-link tests';
  App.Run;
  App.Free;
end.
