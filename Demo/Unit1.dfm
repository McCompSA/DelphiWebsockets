object Form1: TForm1
  Left = 0
  Top = 0
  Caption = 'Form1'
  ClientHeight = 337
  ClientWidth = 635
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  OldCreateOrder = False
  PixelsPerInch = 96
  TextHeight = 13
  object Button1: TButton
    Left = 8
    Top = 8
    Width = 97
    Height = 25
    Caption = 'socket.io'
    TabOrder = 0
    OnClick = Button1Click
  end
  object btnWebsocketsTest: TButton
    Left = 8
    Top = 39
    Width = 97
    Height = 25
    Caption = 'WebSockets'
    TabOrder = 1
    OnClick = btnWebsocketsTestClick
  end
  object cbxUseSSL: TCheckBox
    Left = 24
    Top = 88
    Width = 97
    Height = 17
    Caption = 'use SSL'
    TabOrder = 2
    OnClick = cbxUseSSLClick
  end
  object edtCertFilename: TLabeledEdit
    Left = 24
    Top = 136
    Width = 185
    Height = 21
    EditLabel.Width = 67
    EditLabel.Height = 13
    EditLabel.Caption = 'Cert file name'
    Enabled = False
    TabOrder = 3
    Text = 'd:\mccomp\mccomp.crt'
  end
  object edtKeyFilename: TLabeledEdit
    Left = 24
    Top = 184
    Width = 185
    Height = 21
    EditLabel.Width = 64
    EditLabel.Height = 13
    EditLabel.Caption = 'Key file name'
    Enabled = False
    TabOrder = 4
    Text = 'd:\mccomp\mccomp.key'
  end
  object Timer1: TTimer
    Enabled = False
    Interval = 5000
    OnTimer = Timer1Timer
    Left = 128
    Top = 16
  end
end
