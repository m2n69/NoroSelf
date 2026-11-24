
import runpy
import sys
import asyncio
from getpass import getpass

import qrcode
from telethon.errors import SessionPasswordNeededError

# استفاده از همان کلاینت و همان Session موجود در پروژه
from lib.Information import client


async def qr_authorize():
    await client.connect()

    # اگر قبلاً وارد حساب شده‌ایم، نیازی به QR نیست
    if await client.is_user_authorized():
        print("Already logged in. Starting main.py...")
        return

    print("\nTelegram QR Login")
    print("Scan the QR code using Telegram:")
    print("Settings > Devices > Link Desktop Device\n")

    while True:
        qr_login = await client.qr_login()

        qr = qrcode.QRCode(border=2)
        qr.add_data(qr_login.url)
        qr.make(fit=True)
        qr.print_ascii(invert=True)

        print("\nWaiting for QR scan...")

        try:
            await qr_login.wait(timeout=120)
            break

        except asyncio.TimeoutError:
            print("\nQR code expired. Generating a new one...\n")
            continue

        except SessionPasswordNeededError:
            password = getpass("Enter your Telegram two-step verification password: ")
            await client.sign_in(password=password)
            break

    print("\nLogin successful!")


if __name__ == "__main__":
    try:
        client.loop.run_until_complete(qr_authorize())

        print("\nStarting original main.py...\n")

        # اجرای main.py بدون هیچ تغییری در محتوای آن
        runpy.run_path("main.py", run_name="__main__")

    except KeyboardInterrupt:
        print("\nProgram stopped.")

    finally:
        if client.is_connected():
            client.disconnect()
