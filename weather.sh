#!/usr/bin/env bash
# SETTINGS vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv
#set -x
# API settings ________________________________________________________________

APIKEY=04ded8195fffcc7a2da850b218e574b0
CITY_NAME=Erie,CO #$(cat "$HOME"/.local/bin/.owm-city)       # London
COUNTRY_CODE=US   #$(cat "$HOME"/.local/bin/.owm-country) # UK
# Desired output language
LANG=en #$(cat "$HOME"/.local/bin/.owm-lang) # en
# UNITS can be "metric", "imperial" or "kelvin". Set KNOTS to "yes" if you
# want the wind in knots:

#          | temperature | wind
# -----------------------------------
# metric   | Celsius     | km/h
# imperial | Fahrenheit  | miles/hour
# kelvin   | Kelvin      | km/h

UNITS="imperial"

# Leave "" if you want the default polybar color
COLOR_TEXT=""
# Polybar settings

# Font for the weather icons
WEATHER_FONT_CODE=3

# Font for the thermometer icon
TEMP_FONT_CODE=3

# Wind settings

# Display info about the wind or not. yes/no
DISPLAY_WIND="no"

# Display in knots. yes/no
KNOTS="yes"

# How many decimals after the floating point
DECIMALS=0

# Min. wind force required to display wind info (it depends on what
# measurement unit you have set: knots, m/s or mph). Set to 0 if you always
# want to display wind info. It's ignored if DISPLAY_WIND is false.

MIN_WIND=0

# Display the numeric wind force or not. If not, only the wind icon will
# appear. yes/no

DISPLAY_FORCE="yes"

# Display the wind unit if wind force is displayed. yes/no
DISPLAY_WIND_UNIT="yes"

# Thermometer settings

# When the thermometer icon turns red
HOT_TEMP=75

# When the thermometer icon turns blue
COLD_TEMP=32

# Other settings

# Display the weather description. yes/no
DISPLAY_LABEL="yes"

# Colorize weather icons. yes/no
ICON_COLORS="no"

# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

# Color Settings
if [ $ICON_COLORS = "yes" ]; then
  # Import colors from Xresources
  #background=$(xrdb -query | grep "background" | cut -f2 | head -n 1)
  foreground=$(xrdb -query | grep "foreground" | cut -f2 | head -n 1)
  color0=$(xrdb -query | grep "color0" | cut -f2 | head -n 1)
  color1=$(xrdb -query | grep "color1" | cut -f2 | head -n 1)
  color2=$(xrdb -query | grep "color2" | cut -f2 | head -n 1)
  color3=$(xrdb -query | grep "color3" | cut -f2 | head -n 1)
  color4=$(xrdb -query | grep "color4" | cut -f2 | head -n 1)
  #color5=$(xrdb -query | grep "color5" | cut -f2 | head -n 1)
  #color6=$(xrdb -query | grep "color6" | cut -f2 | head -n 1)
  color7=$(xrdb -query | grep "color7" | cut -f2 | head -n 1)
  #color8=$(xrdb -query | grep "color8" | cut -f2 | head -n 1)
  #color9=$(xrdb -query | grep "color9" | cut -f2 | head -n 1)
  #color10=$(xrdb -query | grep "color10" | cut -f2 | head -n 1)
  #color11=$(xrdb -query | grep "color11" | cut -f2 | head -n 1)
  #color12=$(xrdb -query | grep "color12" | cut -f2 | head -n 1)
  #color13=$(xrdb -query | grep "color13" | cut -f2 | head -n 1)
  #color14=$(xrdb -query | grep "color14" | cut -f2 | head -n 1)
  color15=$(xrdb -query | grep "color15" | cut -f2 | head -n 1)

  # Set colors
  COLOR_CLOUD=${color0}
  COLOR_THUNDER=${color3}
  COLOR_LIGHT_RAIN=${color4}
  COLOR_HEAVY_RAIN=${color15}
  COLOR_SNOW=${foreground}
  COLOR_FOG=${color0}
  COLOR_TORNADO=${color7}
  COLOR_SUN=${color3}
  COLOR_MOON=#9ccfd8
  COLOR_ERR=${color2}
  COLOR_WIND=${color4}
  COLOR_COLD=${color15}
  COLOR_HOT=${color1}
  COLOR_NORMAL_TEMP=${foreground}
else
  # Import colors from Xresources
  foreground=$(xrdb -query | grep "foreground" | cut -f2 | head -n 1)

  # Set colors
  COLOR_CLOUD=${foreground}
  COLOR_THUNDER=${foreground}
  COLOR_LIGHT_RAIN=${foreground}
  COLOR_HEAVY_RAIN=${foreground}
  COLOR_SNOW=${foreground}
  COLOR_FOG=${foreground}
  COLOR_TORNADO=${foreground}
  COLOR_SUN=#f6c177
  COLOR_MOON=#9ccfd8
  COLOR_ERR=${foreground}
  COLOR_WIND=${foreground}
  COLOR_COLD=${foreground}
  COLOR_HOT=#ebbcba
  COLOR_NORMAL_TEMP=${foreground}
fi

if [ "$COLOR_TEXT" != "" ]; then
  COLOR_TEXT_BEGIN="%{F$COLOR_TEXT}"
  COLOR_TEXT_END="%{F-}"
fi

RESPONSE=""
ERROR=0
ERR_MSG=""
if [ $UNITS = "kelvin" ]; then
  UNIT_URL=""
else
  UNIT_URL="&units=$UNITS"
fi
URL="api.openweathermap.org/data/2.5/weather?appid=$APIKEY$UNIT_URL&lang=$LANG&q=$CITY_NAME,$COUNTRY_CODE"

function getData {
  ERROR=0
  # For logging purposes
  # echo " " >> "$HOME/.weather.log"
  # echo `date`" ################################" >> "$HOME/.weather.log"
  RESPONSE=$(curl -s $URL)
  if [ "$1" = "-d" ]; then
    echo "$RESPONSE"
    echo ""
  fi
  CODE=$?
  # echo "Response: $RESPONSE" >> "$HOME/.weather.log"
  RESPONSECODE=0
  if [ $CODE -eq 0 ]; then
    RESPONSECODE=$(echo "$RESPONSE" | jq .cod)
  fi
  if [ $CODE -ne "0" ] || [ "$RESPONSECODE" -ne "200" ]; then
    if [ "$CODE" -ne 0 ]; then
      ERR_MSG="curl Error $CODE"
      # echo "curl Error $CODE" >> "$HOME/.weather.log"
    else
      ERR_MSG="Conn. Err. $RESPONSECODE"
      # echo "API Error $RESPONSECODE" >> "$HOME/.weather.log"
    fi
    ERROR=1
    # else
    #     echo "$RESPONSE" > "$HOME/.weather-last"
    #     echo `date +%s` >> "$HOME/.weather-last"
  fi
}

# Function to return Weather Icons symbol based on OpenWeatherMap weather condition code
get_weather_icon() {
  local condition_code=$1
  case $condition_code in
  200 | 201 | 202 | 230 | 231 | 232) echo "" ;;                   # Thunderstorm with rain
  210 | 211 | 212 | 221) echo "" ;;                               # Thunderstorm
  300 | 301 | 302 | 310 | 311 | 312 | 313 | 314 | 321) echo "" ;; # Drizzle
  500 | 501) echo "" ;;                                           # Light rain
  502 | 503 | 504) echo "" ;;                                     # Heavy rain
  511) echo "" ;;                                                 # Freezing rain
  520 | 521 | 522 | 531) echo "" ;;                               # Shower rain
  600 | 601) echo "" ;;                                           # Light/Moderate snow
  602) echo "" ;;                                                 # Heavy snow
  611 | 612) echo "" ;;                                           # Sleet
  615 | 616) echo "" ;;                                           # Rain and snow
  620 | 621 | 622) echo "" ;;                                     # Snow shower
  701) echo "" ;;                                                 # Mist
  711) echo "" ;;                                                 # Smoke
  721) echo "" ;;                                                 # Haze
  731 | 751) echo "" ;;                                           # Dust/Sand
  741) echo "" ;;                                                 # Fog
  761) echo "" ;;                                                 # Dust
  762) echo "" ;;                                                 # Volcanic ash
  771) echo "" ;;                                                 # Squall
  781) echo "" ;;                                                 # Tornado
  800) echo "" ;;                                                 # Clear sky
  801) echo "" ;;                                                 # Few clouds
  802) echo "" ;;                                                 # Scattered clouds
  803) echo "" ;;                                                 # Broken clouds
  804) echo "" ;;                                                 # Overcast clouds
  900 | 901 | 902) echo "" ;;                                     # Extreme weather
  903) echo "" ;;                                                 # Cold
  904) echo "" ;;                                                 # Hot
  905) echo "" ;;                                                 # Windy
  906) echo "" ;;                                                 # Hail
  951) echo "" ;;                                                 # Calm
  952 | 953 | 954 | 955 | 956) echo "" ;;                         # Breeze/Light/Moderate wind
  957 | 958 | 959 | 960 | 961 | 962) echo "" ;;                   # High wind/Gale/Storm/Hurricane
  *) echo "" ;;                                                   # Default: Clear sky (useful for unknown codes)
  esac
}

# Modified setIcons function
function setIcons {
  ICON=$(get_weather_icon $WID)

  case $WID in
  200 | 201 | 202 | 230 | 231 | 232)
    ICON_COLOR=$COLOR_THUNDER
    ;;
  300 | 301 | 302 | 310 | 311 | 312 | 313 | 314 | 321)
    ICON_COLOR=$COLOR_LIGHT_RAIN
    ;;
  500 | 501 | 502 | 503 | 504 | 511 | 520 | 521 | 522 | 531)
    ICON_COLOR=$COLOR_HEAVY_RAIN
    ;;
  600 | 601 | 602 | 611 | 612 | 615 | 616 | 620 | 621 | 622)
    ICON_COLOR=$COLOR_SNOW
    ;;
  721)
    ICON_COLOR=#c4a7e7
    ;;
  701 | 741)
    ICON_COLOR=$COLOR_FOG
    ;;
  781)
    ICON_COLOR=$COLOR_TORNADO
    ;;
  800)
    if [ "$DATE" -ge "$SUNRISE" ] && [ "$DATE" -le "$SUNSET" ]; then
      ICON_COLOR=$COLOR_SUN
    else
      ICON_COLOR=$COLOR_MOON
    fi
    ;;
  801)
    if [ "$DATE" -ge "$SUNRISE" ] && [ "$DATE" -le "$SUNSET" ]; then
      ICON_COLOR=$COLOR_SUN
    else
      ICON_COLOR=$COLOR_MOON
    fi
    ;;
  803 | 804)
    ICON_COLOR=$COLOR_CLOUD
    ;;
  *)
    ICON_COLOR=$COLOR_ERR
    ;;
  esac

  WIND=""
  WINDFORCE=$(echo "$RESPONSE" | jq .wind.speed)

  if [ $KNOTS = "yes" ]; then
    case $UNITS in
    "imperial")
      WINDFORCE=$(echo "scale=$DECIMALS;$WINDFORCE * 0.8689762419 / 1" | bc)
      ;;
    *)
      WINDFORCE=$(echo "scale=$DECIMALS;$WINDFORCE * 1.943844 / 1" | bc)
      ;;
    esac
  else
    if [ $UNITS != "imperial" ]; then
      WINDFORCE=$(echo "scale=$DECIMALS;$WINDFORCE * 3.6 / 1" | bc)
    else
      WINDFORCE=$(echo "scale=$DECIMALS;$WINDFORCE / 1" | bc)
    fi
  fi

  if [ "$DISPLAY_WIND" = "yes" ] && [ "$(echo "$WINDFORCE >= $MIN_WIND" | bc -l)" -eq 1 ]; then
    WIND="%{T$WEATHER_FONT_CODE}%{F$COLOR_WIND}%{F-}%{T-}"
    if [ $DISPLAY_FORCE = "yes" ]; then
      WIND="$WIND $COLOR_TEXT_BEGIN$WINDFORCE$COLOR_TEXT_END"
      if [ $DISPLAY_WIND_UNIT = "yes" ]; then
        if [ $KNOTS = "yes" ]; then
          WIND="$WIND ${COLOR_TEXT_BEGIN}kn$COLOR_TEXT_END"
        elif [ $UNITS = "imperial" ]; then
          WIND="$WIND ${COLOR_TEXT_BEGIN}mph$COLOR_TEXT_END"
        else
          WIND="$WIND ${COLOR_TEXT_BEGIN}km/h$COLOR_TEXT_END"
        fi
      fi
    fi
    WIND="$WIND |"
  fi

  if [ "$UNITS" = "metric" ]; then
    TEMP_ICON="糖"
  elif [ "$UNITS" = "imperial" ]; then
    TEMP_ICON=""
  else
    TEMP_ICON="洞"
  fi

  TEMP=$(echo "$TEMP" | cut -d "." -f 1)

  if [ "$TEMP" -le $COLD_TEMP ]; then
    TEMP="%{F$COLOR_COLD}%{T$TEMP_FONT_CODE}%{T-}%{F-} $COLOR_TEXT_BEGIN$TEMP%{T$TEMP_FONT_CODE} $TEMP_ICON%{T-}$COLOR_TEXT_END"
  elif [ "$(echo "$TEMP >= $HOT_TEMP" | bc)" -eq 1 ]; then
    TEMP="%{F$COLOR_HOT}%{T$TEMP_FONT_CODE}%{T-}%{F-} $COLOR_TEXT_BEGIN$TEMP%{T$TEMP_FONT_CODE} $TEMP_ICON%{T-}$COLOR_TEXT_END"
  else
    TEMP="%{F$COLOR_NORMAL_TEMP}%{T$TEMP_FONT_CODE}%{T-}%{F-} $COLOR_TEXT_BEGIN$TEMP%{T$TEMP_FONT_CODE} $TEMP_ICON%{T-}$COLOR_TEXT_END"
  fi
}

#function setIcons {
#  if [ "$WID" -le 232 ]; then
#    #Thunderstorm
#    ICON_COLOR=$COLOR_THUNDER
#    if [ "$DATE" -ge "$SUNRISE" ] && [ "$DATE" -le "$SUNSET" ]; then
#      ICON=""
#    else
#      ICON=""
#    fi
#  elif [ "$WID" -le 311 ]; then
#    #Light drizzle
#    ICON_COLOR=$COLOR_LIGHT_RAIN
#    if [ "$DATE" -ge "$SUNRISE" ] && [ "$DATE" -le "$SUNSET" ]; then
#      ICON=""
#    else
#      ICON=""
#    fi
#  elif [ "$WID" -le 321 ]; then
#    #Heavy drizzle
#    ICON_COLOR=$COLOR_HEAVY_RAIN
#    if [ "$DATE" -ge "$SUNRISE" ] && [ "$DATE" -le "$SUNSET" ]; then
#      ICON=""
#    else
#      ICON=""
#    fi
#  elif [ "$WID" -le 531 ]; then
#    #Rain
#    ICON_COLOR=$COLOR_HEAVY_RAIN
#    if [ "$DATE" -ge "$SUNRISE" ] && [ "$DATE" -le "$SUNSET" ]; then
#      ICON=""
#    else
#      ICON=""
#    fi
#  elif [ "$WID" -le 622 ]; then
#    #Snow
#    ICON_COLOR=$COLOR_SNOW
#    ICON=""
#  elif [ "$WID" -le 721 ]; then
#    #haze
#    ICON_COLOR=#c4a7e7
#    ICON=""
#  elif [ "$WID" -le 771 ]; then
#    #Fog
#    ICON_COLOR=$COLOR_FOG
#    ICON=""
#
#  elif [ "$WID" -eq 781 ]; then
#    #Tornado
#    ICON_COLOR=$COLOR_TORNADO
#    ICON=""
#  elif [ "$WID" -eq 800 ]; then
#    #Clear sky
#    if [ "$DATE" -ge "$SUNRISE" ] && [ "$DATE" -le "$SUNSET" ]; then
#      ICON_COLOR=$COLOR_SUN
#      ICON=""
#    else
#      ICON_COLOR=$COLOR_MOON
#      ICON=""
#    fi
#  elif [ "$WID" -eq 801 ]; then
#    # Few clouds
#    if [ "$DATE" -ge "$SUNRISE" ] && [ "$DATE" -le "$SUNSET" ]; then
#      ICON_COLOR=$COLOR_SUN
#      ICON=""
#    else
#      ICON_COLOR=$COLOR_MOON
#      ICON=""
#    fi
#  elif [ "$WID" -eq 803 ]; then
#    # Broken Clouds
#    if [ "$DATE" -ge "$SUNRISE" ] && [ "$DATE" -le "$SUNSET" ]; then
#      ICON_COLOR=$COLOR_SUN
#      ICON=""
#    else
#      ICON_COLOR=$COLOR_MOON
#      ICON=""
#    fi
#  elif [ "$WID" -le 804 ]; then
#    # Overcast
#    ICON_COLOR=$COLOR_CLOUD
#    ICON=""
#  else
#    ICON_COLOR=$COLOR_ERR
#    ICON=""
#  fi
#  WIND=""
#  WINDFORCE=$(echo "$RESPONSE" | jq .wind.speed)
#  if [ $KNOTS = "yes" ]; then
#    case $UNITS in
#    "imperial")
#      # The division by one is necessary because scale works only for divisions. bc is stupid.
#      WINDFORCE=$(echo "scale=$DECIMALS;$WINDFORCE * 0.8689762419 / 1" | bc)
#      ;;
#    *)
#      WINDFORCE=$(echo "scale=$DECIMALS;$WINDFORCE * 1.943844 / 1" | bc)
#      ;;
#    esac
#  else
#    if [ $UNITS != "imperial" ]; then
#      # Conversion from m/s to km/h
#      WINDFORCE=$(echo "scale=$DECIMALS;$WINDFORCE * 3.6 / 1" | bc)
#    else
#      WINDFORCE=$(echo "scale=$DECIMALS;$WINDFORCE / 1" | bc)
#    fi
#  fi
#  if [ "$DISPLAY_WIND" = "yes" ] && [ "$(echo "$WINDFORCE >= $MIN_WIND" | bc -l)" -eq 1 ]; then
#    WIND="%{T$WEATHER_FONT_CODE}%{F$COLOR_WIND}%{F-}%{T-}"
#    if [ $DISPLAY_FORCE = "yes" ]; then
#      WIND="$WIND $COLOR_TEXT_BEGIN$WINDFORCE$COLOR_TEXT_END"
#      if [ $DISPLAY_WIND_UNIT = "yes" ]; then
#        if [ $KNOTS = "yes" ]; then
#          WIND="$WIND ${COLOR_TEXT_BEGIN}kn$COLOR_TEXT_END"
#        elif [ $UNITS = "imperial" ]; then
#          WIND="$WIND ${COLOR_TEXT_BEGIN}mph$COLOR_TEXT_END"
#        else
#          WIND="$WIND ${COLOR_TEXT_BEGIN}km/h$COLOR_TEXT_END"
#        fi
#      fi
#    fi
#    WIND="$WIND |"
#  fi
#  if [ "$UNITS" = "metric" ]; then
#    TEMP_ICON="糖"
#  elif [ "$UNITS" = "imperial" ]; then
#    TEMP_ICON=""
#  else
#    TEMP_ICON="洞"
#  fi
#
#  TEMP=$(echo "$TEMP" | cut -d "." -f 1)
#
#  if [ "$TEMP" -le $COLD_TEMP ]; then
#    TEMP="%{F$COLOR_COLD}%{T$TEMP_FONT_CODE}%{T-}%{F-} $COLOR_TEXT_BEGIN$TEMP%{T$TEMP_FONT_CODE} $TEMP_ICON%{T-}$COLOR_TEXT_END"
#  elif [ "$(echo "$TEMP >= $HOT_TEMP" | bc)" -eq 1 ]; then
#    TEMP="%{F$COLOR_HOT}%{T$TEMP_FONT_CODE}%{T-}%{F-} $COLOR_TEXT_BEGIN$TEMP%{T$TEMP_FONT_CODE} $TEMP_ICON%{T-}$COLOR_TEXT_END"
#  else
#    TEMP="%{F$COLOR_NORMAL_TEMP}%{T$TEMP_FONT_CODE}%{T-}%{F-} $COLOR_TEXT_BEGIN$TEMP%{T$TEMP_FONT_CODE} $TEMP_ICON%{T-}$COLOR_TEXT_END"
#  fi
#}
#
function outputCompact {
  if [ -z ${WIND+x} ]; then
    OUTPUT="$WIND %{T$WEATHER_FONT_CODE}%{F$ICON_COLOR}$ICON%{F-}%{T-} $COLOR_TEXT_BEGIN$DESCRIPTION$COLOR_TEXT_END $TEMP"
  fi
  OUTPUT="$CITY_NAME: %{T$WEATHER_FONT_CODE}%{F$ICON_COLOR}$ICON%{F-}%{T-} $COLOR_TEXT_BEGIN$DESCRIPTION$COLOR_TEXT_END $TEMP"
  # echo "Output: $OUTPUT" >> "$HOME/.weather.log"
  echo "$OUTPUT"
}

getData "$1"
if [ $ERROR -eq 0 ]; then
  #MAIN=$(echo "$RESPONSE" | jq .weather[0].main)
  WID=$(echo "$RESPONSE" | jq .weather[0].id)
  #DESC=$(echo "$RESPONSE" | jq .weather[0].description)
  SUNRISE=$(echo "$RESPONSE" | jq .sys.sunrise)
  SUNSET=$(echo "$RESPONSE" | jq .sys.sunset)
  DATE=$(date +%s)
  WIND=""
  TEMP=$(echo "$RESPONSE" | jq .main.temp)
  if [ $DISPLAY_LABEL = "yes" ]; then
    DESCRIPTION=$(echo "$RESPONSE" | jq .weather[0].description | tr -d '"' | sed 's/.*/\L&/; s/[a-z]*/\u&/g')" "
  else
    DESCRIPTION=""
  fi
  #PRESSURE=$(echo "$RESPONSE" | jq .main.pressure)
  #HUMIDITY=$(echo "$RESPONSE" | jq .main.humidity)
  setIcons
  outputCompact
else
  echo " "
fi
