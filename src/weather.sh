#!/bin/bash

location=$(curl -s "https://ipinfo.io" | jq ".loc")
latitude=$(echo $location | cut -d "," -f 1 | sed s/[\"]//g)
longitude=$(echo $location | cut -d "," -f 2 | sed s/[\"]//g)
source ~/.config/waybar/.env
weather=$(curl -s "https://api.openweathermap.org/data/3.0/onecall?lat=$latitude&lon=$longitude&units=metric&exclude=minutely,hourly,daily,alerts&appid=$OPENWEATHER_API" | jq ".current.temp")
echo $weather"°C"
