# Bring your own cat to Meowverse

[简体中文](README.md) | English · [Back to the project](../../README.en.md)

Want your cat to live in Meowverse? Use the gray guides and prompts below to prepare multi-view reference images in your own ChatGPT account, then send us only the generated images you have selected. We can review them for a manually prepared cat pack.

**Preparation and review are manual. Participation is optional, and submitting a request does not guarantee acceptance, completion or a delivery date.** The app currently imports finished `.meowcat` files; it does not automatically turn reference images into a cat.

**[Submit your generated cat references →](https://github.com/Fengyee/meowverse-core/issues/new?template=03-cat-reference.yml)** · [Collection thread / upload in a comment](https://github.com/Fengyee/meowverse-core/issues/1)

**Public submission:** this repository, its issues, comments and attachments can be viewed and downloaded by other people. Attaching a file uploads it to GitHub immediately, before you create the issue. Check the image, filename and metadata before attaching it. Do not use this route for anything you do not want to make public.

## Download the reference materials

- **[Pose overview (PNG)](POSE_GUIDE.png):** the unmarked gray model from all eight cameras on one sheet. Used in message 1.
- **[Eight single-view guides (guides/)](guides/):** `01_FRONT.png` … `08_HEAD_RIGHT.png`, one for each of messages 2–9.
- **[Ten prompts (prompts/)](prompts/):** `00_SHEET.txt` … `09_PACKAGE.txt`. Copy them in file-name order; no editing needed.
- **[User kit (ZIP)](Meowverse-Cat-Reference-Kit.zip):** everything above, plus the bilingual instructions, attribution and Bella posters. It includes no private photographs, production app models or design sources.

The gray guides control pose, camera and framing, not the cat's identity. The poster below shows the earlier one-message version of this workflow; follow the steps on this page. **Upload the gray guides, not the poster.** Its QR code opens this guide, and the poster also gives the repository address and its “Bring your own cat” entry for people who cannot scan it.

[![English illustrated guide featuring Bella: prepare references, generate views, submit selected images and import a finished cat pack](cat-creation-flow-bella-en.png)](cat-creation-flow-bella-en.png)

## 1. Choose your photographs

Pick a few clear photographs of your own cat. Where possible, show the face, both sides and back, with the markings, paws and tail visible. Use photos you have the right to provide, without human faces, addresses, identity documents or other private information.

**You upload the real photographs to ChatGPT yourself, not to the Meowverse preparation request.** They are sent to the third-party service you choose and are handled under its policies and your account settings. This is not an on-device generation workflow. Decide whether you are comfortable using that service before uploading.

## 2. Send ten messages in one new conversation

Attach **only one gray guide to each message**. Wait until the image is finished and the one-line self-check is written before sending the next message. Several guides in one message tend to come back as another contact sheet.

| Message | Attach | Paste | Result |
| --- | --- | --- | --- |
| 1 | `POSE_GUIDE.png` and all your cat photographs | `00_SHEET.txt` | An eight-panel sheet that settles what the cat looks like |
| 2 | `guides/01_FRONT.png` | `01_FRONT.txt` | Full body, front |
| 3 | `guides/02_LEFT.png` | `02_LEFT.txt` | Full body, side view facing left in the image |
| 4 | `guides/03_RIGHT.png` | `03_RIGHT.txt` | Full body, side view facing right in the image |
| 5 | `guides/04_BACK.png` | `04_BACK.txt` | Full body, back |
| 6 | `guides/05_TOP.png` | `05_TOP.txt` | Full body, top view with the head toward the top |
| 7 | `guides/06_HEAD_FRONT.png` | `06_HEAD_FRONT.txt` | Head, front |
| 8 | `guides/07_HEAD_LEFT.png` | `07_HEAD_LEFT.txt` | Head, side view facing left in the image |
| 9 | `guides/08_HEAD_RIGHT.png` | `08_HEAD_RIGHT.txt` | Head, side view facing right in the image |
| 10 | nothing | `09_PACKAGE.txt` | `cat_views.zip`: the sheet, eight views and a short report |

- In message 1, include the photographs that show the markings best. If the sheet does not look like your cat, redo that step: the eight views are all drawn from it.
- After each image ChatGPT writes a one-line self-check; read it. If a view is wrong (facing the wrong way, legs or tail out of place, cat too large, a signature marking missing), send **that message again with its guide**, preceded by one sentence saying what is wrong. Packaging uses the last image made for each view.
- Head close-ups most often lose a signature marking or draw the head too large. When resending, say what was lost, for example “the black spot on the nose is missing”. For the side views, compare against the guide: ear tips about 10% from the top edge, nose tip about 11% from the side edge, eye at about 45% of the height, mouth line at about 63%.
- Sometimes ChatGPT offers two images to choose from. Pick the one whose size and position match the guide.
- After message 10, download the ZIP and read the report inside: it lists what it admits it did not get right.

## 3. Check and submit only the generated references

Put each view next to the guide with the same name: the camera, the direction of the nose, the legs and tail, and the cat's size and position should all match. Then check that the images depict the same cat: face shape, body proportions, eye color and marking boundaries should agree, and left and right markings should not simply be mirrored. The cat should stand with all four paws planted on one ground plane, with every visible paw inside the frame and the tail extending straight backward. In an exact side profile, far-side legs may be hidden behind the near legs. The gray guide helps you check framing; you still decide whether the result resembles your cat.

The ZIP from message 10 already names the views `01_FRONT.png` … `08_HEAD_RIGHT.png` and can be submitted as is. Open it first and confirm it holds only generated images and the report, with no source photographs. If packaging fails, download each full-resolution image instead, name it as in the table and make the ZIP yourself. Do not submit screenshots of the ChatGPT page.

Sign in to GitHub and open the **[cat-reference request form](https://github.com/Fengyee/meowverse-core/issues/new?template=03-cat-reference.yml)**. A GitHub account is required to submit an issue. Choose a public cat nickname and attach only the generated references you want reviewed. Use one issue per cat to track reference corrections, progress and delivery arrangements. Whether a finished pack is shared publicly requires separate agreement.

Alternatively, attach your selected images or ZIP in a comment on the **[collection thread](https://github.com/Fengyee/meowverse-core/issues/1)** using its suggested format. The same public visibility and project-use boundaries apply.

**Do not attach real source photographs, chat screenshots, transcripts, chat-sharing links or account credentials.** Do not include human faces, addresses, identity documents, payment details, real API keys or device identifiers. Generated images can still reproduce background details or text from a source photo; they are not an anonymity guarantee.

Attachment guidelines:

- For direct PNG/JPG/JPEG uploads, keep **each image at or below 10 MB**.
- For several images, a ZIP of **20 MB or less is recommended**. GitHub's limit for other attachments is **25 MB per file**. If needed, split the generated images across two archives or reduce their size appropriately.
- Put **only the selected generated reference images** in the ZIP. Check it contains no original photos, conversation records or unrelated private files.
- Wait until attachments finish uploading before creating the issue. A local file path is not an attachment. The 20 MB recommendation is for convenience, not an additional automatic size check.

GitHub documents its limits and upload behavior in [Attaching files](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files).

## 4. Import a finished cat pack when one is provided

A maintainer first checks the references and, where suitable, attempts the model, animation adaptation and pack checks. Images alone do not guarantee a successful model. Missing views or other questions can be discussed in the issue. There is no one-click automatic cat-creation flow in the app.

If a pack is completed, follow the agreed delivery arrangements to obtain the `.meowcat` file. The issue can be used to coordinate delivery; publishing the finished pack is a separate decision requiring agreement. In an app build with cat-pack import, open:

**Room → More (…) → Settings → Cat models → Import Cat Model…**

Select the finished file, let the app validate the import, then switch to your cat. If your installed beta does not show that entry, mention its build number in the issue and wait for compatibility guidance. Reference PNGs and ZIPs are not finished `.meowcat` packs.

## Public visibility and how the project may use your references

Only submit generated images you have the right to make public and allow a maintainer to process for this reference review and cat-pack request. Public posting does not give you control over copies other people may save; deleting an issue cannot recall those copies.

**Meowverse will not treat a reference submission as blanket permission to add your cat to the app's built-in collection, use it for training, or publish the images or model in an asset library or another commercial release.** Those additional project uses, including publicly sharing the finished `.meowcat` pack, need separate confirmation. If you would like to discuss wider availability, say so in the notes; the specific use and delivery scope must still be agreed separately.

User-submitted reference artwork is not automatically covered by the repository's noncommercial code license. GitHub's own hosting and service terms still apply to content uploaded there; these project-use boundaries do not change the platform's public visibility or its terms.

The instructions, gray pose template and Bella illustration have their own scopes of use. See [Attribution and usage](ATTRIBUTION.md) and the [repository license scope](../../LICENSE-SCOPE.en.md).
