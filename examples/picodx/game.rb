require 'picodx'

Window.bgcolor = [20, 20, 40]

ball = Image.new(24, 24, [255, 80, 80])
x, y = 300, 200
dx, dy = 4, 3

Window.loop do
  x += dx
  y += dy
  dx = -dx if x < 0 || x > Window.width - 24
  dy = -dy if y < 0 || y > Window.height - 24
  Window.draw(x, y, ball)
  Window.draw_font(8, 8, "Hello from require 'picodx'!", [255, 255, 255])
end
