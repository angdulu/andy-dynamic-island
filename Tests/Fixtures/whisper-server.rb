#!/usr/bin/ruby
require 'socket'

model = ARGV[ARGV.index('--model') + 1]
port = Integer(ARGV[ARGV.index('--port') + 1])
mode = File.read(model).strip
File.open(model + '.launches', 'a') { |file| file.puts(Process.pid) }
if mode == 'exit'
  warn 'fixture model cannot be loaded'
  exit 1
end
sleep(mode == 'slow' ? 0.8 : 0.2)
server = TCPServer.new('127.0.0.1', port)
loop do
  client = server.accept
  while (line = client.gets) && line != "\r\n"
  end
  client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
  client.close
end
