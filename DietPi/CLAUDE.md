Scripts DietPi communs à mes Raspberry Pi, une carte = un profil (option -B de DietPi_Download.sh et DietPi_Customize.sh, fonction board_profile).

rpi3b : Raspberry Pi 3b v1.2
- Touchscreen Waveshare 10.1inch HDMI LCD, 1024x600px, XPT2046 touch controller
- Camera Raspberry pi rev 1.3
- En I2C : gyro/accéléromètre (MPU-6050 / GY-521), bmp180 (ou BME280 plus tard)
- Carte SD 32G
- Ground station FPV (option -G on) : FPVTools/esp-tracker en service, kiosque Chromium dessus ; tracker ESP32 et
  dongle de capture HDMI (vidéo des lunettes) en USB. Le MPU-6050 et le BMP180 ne servent pas à la ground station.

rpi2 : Raspberry Pi 2
- Touchscreen 5" HDMI 800x480, tactile résistif (XPT2046 sur le GPIO)
- Pas d'I2C ni de caméra pour l'instant
- Pas de Wi-Fi intégré : clé USB à prévoir, avec un driver dans le noyau (la clé AIC8800FC n'en a pas)
