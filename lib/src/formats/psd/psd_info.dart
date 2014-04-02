part of image;

class PsdInfo extends DecodeInfo {
  // SIGNATURE is '8BPS'
  static const int SIGNATURE = 0x38425053;

  static const int COLORMODE_BITMAP = 0;
  static const int COLORMODE_GRAYSCALE = 1;
  static const int COLORMODE_INDEXED = 2;
  static const int COLORMODE_RGB = 3;
  static const int COLORMODE_CMYK = 4;
  static const int COLORMODE_MULTICHANNEL = 7;
  static const int COLORMODE_DUOTONE = 8;
  static const int COLORMODE_LAB = 9;

  InputBuffer input;
  int signature;
  int version;
  int channels;
  int depth;
  int colorMode;
  InputBuffer colorData;
  InputBuffer imageResourceData;
  InputBuffer layerAndMaskData;
  InputBuffer imageData;
  List<PsdLayer> layers;
  List<PsdChannel> baseImage;

  PsdInfo(List<int> bytes) {
    input = new InputBuffer(bytes, bigEndian: true);

    _readHeader();
    if (!isValid) {
      return;
    }

    int len = input.readUint32();
    colorData = input.readBytes(len);

    len = input.readUint32();
    imageResourceData = input.readBytes(len);

    len = input.readUint32();
    layerAndMaskData = input.readBytes(len);

    len = input.readUint32();
    imageData = input.readBytes(len);
  }

  bool get isValid => signature == SIGNATURE;

  /// The number of frames that can be decoded.
  int get numFrames => 1;

  /**
   * Decode the raw psd structure without rendering the output image.
   * Use [renderImage] to render the output image.
   */
  bool decode() {
    if (!isValid) {
      return false;
    }

    // Color Mode Data Block:
    // Indexed and duotone images have palette data in colorData...
    _readColorModeData();

    // Image Resource Block:
    // Image resources are used to store non-pixel data associated with images,
    // such as pen tool paths.
    _readImageResources();

    _readLayerAndMaskData();

    _readBaseLayer();

    return true;
  }

  Image decodeImage() {
    if (!decode()) {
      return null;
    }

    return renderImage();
  }

  Image renderImage() {
    Image output = new Image(width, height);

    Uint8List pixels = output.getBytes();

    for (int y = 0, di = 0, si = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x, ++si) {
        int r = baseImage[0].data[si];
        int g = baseImage[1].data[si];
        int b = baseImage[2].data[si];
        int a = baseImage[3].data[si];
        pixels[di++] = r;
        pixels[di++] = g;
        pixels[di++] = b;
        pixels[di++] = a;
      }
    }

    for (int li = 0; li < layers.length; ++li) {
      PsdLayer layer = layers[li];
      PsdChannel red = layer.getChannel(PsdChannel.CHANNEL_RED);
      PsdChannel green = layer.getChannel(PsdChannel.CHANNEL_GREEN);
      PsdChannel blue = layer.getChannel(PsdChannel.CHANNEL_BLUE);
      PsdChannel alpha = layer.getChannel(PsdChannel.CHANNEL_ALPHA);

      double opacity = layer.opacity / 255.0;
      int blendMode = layer.blendMode;
      print('BLEND: ${layer.blendMode.toRadixString(16)} $opacity');

      for (int y = layer.top, si = 0; y < layer.bottom; ++y) {
        int di = y * width * 4 + layer.left * 4;
        for (int x = layer.left; x < layer.right; ++x, ++si, di += 4) {
          int br = (red != null) ? red.data[si] : 0;
          int bg = (green != null) ? green.data[si] : 0;
          int bb = (blue != null) ? blue.data[si] : 0;
          int ba = (alpha != null) ? alpha.data[si] : 255;

          int ar = pixels[di];
          int ag = pixels[di + 1];
          int ab = pixels[di + 2];
          int aa = pixels[di + 3];

          _blend(ar, ag, ab, aa, br, bg, bb, ba, blendMode, opacity,
                 pixels, di);
        }
      }
    }

    return output;
  }

  void _blend(int ar, int ag, int ab, int aa,
              int br, int bg, int bb, int ba,
              int blendMode, double opacity, Uint8List pixels, int di) {
    int r = br;
    int g = bg;
    int b = bb;
    int a = ba;
    double da = (ba / 255.0) * opacity;

    switch (blendMode) {
      case PsdLayer.BLEND_OVERLAY:
        double ard = ar / 255.0;
        double agd = ag / 255.0;
        double abd = ab / 255.0;
        double aad = aa / 255.0;
        double brd = br / 255.0;
        double bgd = bg / 255.0;
        double bbd = bb / 255.0;
        double bad = ba / 255.0;

        double _ra;
        if (2.0 * ard < aad) {
          _ra = 2.0 * brd * ard + brd * (1.0 - aad) + ard * (1.0 - bad);
        } else {
          _ra = bad * aad - 2.0 * (aad - ard) * (bad - brd) +
                brd * (1.0 - aad) + ard * (1.0 - bad);
        }

        double _ga;
        if (2.0 * agd < aad) {
          _ga = 2.0 * bgd * agd + bgd * (1.0 - aad) + agd * (1.0 - bad);
        } else {
          _ga = bad * aad - 2.0 * (aad - agd) * (bad - bgd) +
                bgd * (1.0 - aad) + agd * (1.0 - bad);
        }

        double _ba;
        if (2.0 * abd < aad) {
          _ba = 2.0 * bbd * abd + bbd * (1.0 - aad) + abd * (1.0 - bad);
        } else {
          _ba = bad * aad - 2.0 * (aad - abd) * (bad - bbd) +
                bbd * (1.0 - aad) + abd * (1.0 - bad);
        }

        r = (_ra * 255.0).toInt();
        g = (_ga * 255.0).toInt();
        b = (_ba * 255.0).toInt();
        break;
    }

    r = ((ar * (1.0 - da)) + (r * da)).toInt();
    g = ((ag * (1.0 - da)) + (g * da)).toInt();
    b = ((ab * (1.0 - da)) + (b * da)).toInt();
    a = ((aa * (1.0 - da)) + (a * da)).toInt();

    pixels[di++] = r;
    pixels[di++] = g;
    pixels[di++] = b;
    pixels[di++] = a;
  }

  void _readHeader() {
    signature = input.readUint32();
    version = input.readUint16();

    // version should be 1 (2 for PSB files).
    if (version != 1) {
      signature = 0;
      return;
    }

    // padding should be all 0's
    InputBuffer padding = input.readBytes(6);
    for (int i = 0; i < 6; ++i) {
      if (padding[i] != 0) {
        signature = 0;
        return;
      }
    }

    channels = input.readUint16();
    height = input.readUint32();
    width = input.readUint32();
    depth = input.readUint16();
    colorMode = input.readUint16();
  }

  void _readColorModeData() {
    // TODO support indexed and duotone images.
  }

  void _readImageResources() {
    imageResourceData.rewind();
    while (!imageResourceData.isEOS) {
      int blockSignature = imageResourceData.readUint32();
      int blockId = imageResourceData.readUint16();

      int len = imageResourceData.readByte();
      String blockName = imageResourceData.readString(len);
      // name string is padded to an even size
      if (len & 1 == 0) {
        imageResourceData.skip(1);
      }

      len = imageResourceData.readUint32();
      InputBuffer blockData = imageResourceData.readBytes(len);
      // blocks are padded to an even length.
      if (len & 1 == 1) {
        imageResourceData.skip(1);
      }

      if (blockSignature == RESOURCE_BLOCK_SIGNATURE) {
        imageResources[blockId] = new PsdImageResource(blockId, blockName,
                                                       blockData);
      }
    }
  }

  void _readLayerAndMaskData() {
    layerAndMaskData.rewind();
    int len = layerAndMaskData.readUint32();
    if ((len & 1) != 0) {
      len++;
    }

    layers = [];
    if (len > 0) {
      int count = layerAndMaskData.readUint16();
      for (int i = 0; i < count; ++i) {
        PsdLayer layer = new PsdLayer(layerAndMaskData);
        layers.add(layer);
      }
    }

    for (int i = 0; i < layers.length; ++i) {
      layers[i].readImageData(layerAndMaskData);
    }
  }

  void _readBaseLayer() {
    imageData.rewind();
    const List<int> channelIds = const [PsdChannel.CHANNEL_RED,
                                        PsdChannel.CHANNEL_GREEN,
                                        PsdChannel.CHANNEL_BLUE,
                                        PsdChannel.CHANNEL_ALPHA];

    int compression = imageData.readUint16() == 1 ? 1 : 0;

    Uint16List lineLengths;
    if (compression == PsdChannel.COMPRESS_RLE) {
      int numLines = height * this.channels;
      lineLengths = new Uint16List(numLines);
      for (int i = 0; i < numLines; ++i) {
        lineLengths[i] = imageData.readUint16();
      }
    }

    baseImage = [];

    int planeNumber = 0;
    for (int i = 0; i < channelIds.length; ++i) {
      baseImage.add(new PsdChannel.base(imageData, channelIds[i], width, height,
                                        compression, lineLengths, i));
    }
  }

  // '8BIM'
  static const int RESOURCE_BLOCK_SIGNATURE = 0x3842494d;

  Map<int, PsdImageResource> imageResources = {};

  /*0x03E8 (Obsolete--Photoshop 2.0 only ) Contains five 2-byte values: number of channels, rows, columns, depth, and mode
  0x03E9 Macintosh print manager print info record
  0x03EB (Obsolete--Photoshop 2.0 only ) Indexed color table
  0x03ED ResolutionInfo structure. See Appendix A in Photoshop API Guide.pdf.
  0x03EE Names of the alpha channels as a series of Pascal strings.
  0x03EF (Obsolete) See ID 1077DisplayInfo structure. See Appendix A in Photoshop API Guide.pdf.
  0x03F0 The caption as a Pascal string.
  0x03F1 Border information. Contains a fixed number (2 bytes real, 2 bytes fraction) for the border width, and 2 bytes for border units (1 = inches, 2 = cm, 3 = points, 4 = picas, 5 = columns).
  0x03F2 Background color. See See Color structure.
  0x03F3 Print flags. A series of one-byte boolean values (see Page Setup dialog): labels, crop marks, color bars, registration marks, negative, flip, interpolate, caption, print flags.
  0x03F4 Grayscale and multichannel halftoning information
  0x03F5 Color halftoning information
  0x03F6 Duotone halftoning information
  0x03F7 Grayscale and multichannel transfer function
  0x03F8 Color transfer functions
  0x03F9 Duotone transfer functions
  0x03FA Duotone image information
  0x03FB Two bytes for the effective black and white values for the dot range
  0x03FC (Obsolete)
  0x03FD EPS options
  0x03FE Quick Mask information. 2 bytes containing Quick Mask channel ID; 1- byte boolean indicating whether the mask was initially empty.
  0x03FF (Obsolete)
  0x0400 Layer state information. 2 bytes containing the index of target layer (0 = bottom layer).
  0x0401 Working path (not saved). See See Path resource format.
  0x0402 Layers group information. 2 bytes per layer containing a group ID for the dragging groups. Layers in a group have the same group ID.
  0x0403 (Obsolete)
  0x0404 IPTC-NAA record. Contains the File Info... information. See the documentation in the IPTC folder of the Documentation folder.
  0x0405 Image mode for raw format files
  0x0406 JPEG quality. Private.
  0x0408 (Photoshop 4.0) Grid and guides information. See See Grid and guides resource format.
  0x0409 (Photoshop 4.0) Thumbnail resource for Photoshop 4.0 only. See See Thumbnail resource format.
  0x040A (Photoshop 4.0) Copyright flag. Boolean indicating whether image is copyrighted. Can be set via Property suite or by user in File Info...
  0x040B (Photoshop 4.0) URL. Handle of a text string with uniform resource locator. Can be set via Property suite or by user in File Info...
  0x040C (Photoshop 5.0) Thumbnail resource (supersedes resource 1033). See See Thumbnail resource format.
  0x040D (Photoshop 5.0) Global Angle. 4 bytes that contain an integer between 0 and 359, which is the global lighting angle for effects layer. If not present, assumed to be 30.
  0x040E (Obsolete) See ID 1073 below. (Photoshop 5.0) Color samplers resource. See See Color samplers resource format.
  0x040F (Photoshop 5.0) ICC Profile. The raw bytes of an ICC (International Color Consortium) format profile. See ICC1v42_2006-05.pdf in the Documentation folder and icProfileHeader.h in Sample Code\Common\Includes .
  0x0410 (Photoshop 5.0) Watermark. One byte.
  0x0411 (Photoshop 5.0) ICC Untagged Profile. 1 byte that disables any assumed profile handling when opening the file. 1 = intentionally untagged.
  0x0412 (Photoshop 5.0) Effects visible. 1-byte global flag to show/hide all the effects layer. Only present when they are hidden.
  0x0413 (Photoshop 5.0) Spot Halftone. 4 bytes for version, 4 bytes for length, and the variable length data.
  0x0414 (Photoshop 5.0) Document-specific IDs seed number. 4 bytes: Base value, starting at which layer IDs will be generated (or a greater value if existing IDs already exceed it). Its purpose is to avoid the case where we add layers, flatten, save, open, and then add more layers that end up with the same IDs as the first set.
  0x0415 (Photoshop 5.0) Unicode Alpha Names. Unicode string
  0x0416 (Photoshop 6.0) Indexed Color Table Count. 2 bytes for the number of colors in table that are actually defined
  0x0417 (Photoshop 6.0) Transparency Index. 2 bytes for the index of transparent color, if any.
  0x0419 (Photoshop 6.0) Global Altitude. 4 byte entry for altitude
  0x041A (Photoshop 6.0) Slices. See See Slices resource format.
  0x041B (Photoshop 6.0) Workflow URL. Unicode string
  0x041C (Photoshop 6.0) Jump To XPEP. 2 bytes major version, 2 bytes minor version, 4 bytes count. Following is repeated for count: 4 bytes block size, 4 bytes key, if key = 'jtDd' , then next is a Boolean for the dirty flag; otherwise it's a 4 byte entry for the mod date.
  0x041D (Photoshop 6.0) Alpha Identifiers. 4 bytes of length, followed by 4 bytes each for every alpha identifier.
  0x041E (Photoshop 6.0) URL List. 4 byte count of URLs, followed by 4 byte long, 4 byte ID, and Unicode string for each count.
  0x0421 (Photoshop 6.0) Version Info. 4 bytes version, 1 byte hasRealMergedData , Unicode string: writer name, Unicode string: reader name, 4 bytes file version.
  0x0422 (Photoshop 7.0) EXIF data 1. See http://www.kodak.com/global/plugins/acrobat/en/service/digCam/exifStandard2.pdf
  0x0423 (Photoshop 7.0) EXIF data 3. See http://www.kodak.com/global/plugins/acrobat/en/service/digCam/exifStandard2.pdf
  0x0424 (Photoshop 7.0) XMP metadata. File info as XML description. See http://www.adobe.com/devnet/xmp/
  0x0425 (Photoshop 7.0) Caption digest. 16 bytes: RSA Data Security, MD5 message-digest algorithm
  0x0426 (Photoshop 7.0) Print scale. 2 bytes style (0 = centered, 1 = size to fit, 2 = user defined). 4 bytes x location (floating point). 4 bytes y location (floating point). 4 bytes scale (floating point)
  0x0428 (Photoshop CS) Pixel Aspect Ratio. 4 bytes (version = 1 or 2), 8 bytes double, x / y of a pixel. Version 2, attempting to correct values for NTSC and PAL, previously off by a factor of approx. 5%.
  0x0429 (Photoshop CS) Layer Comps. 4 bytes (descriptor version = 16), Descriptor (see See Descriptor structure)
  0x042A (Photoshop CS) Alternate Duotone Colors. 2 bytes (version = 1), 2 bytes count, following is repeated for each count: [ Color: 2 bytes for space followed by 4 * 2 byte color component ], following this is another 2 byte count, usually 256, followed by Lab colors one byte each for L, a, b. This resource is not read or used by Photoshop.
  0x042B (Photoshop CS)Alternate Spot Colors. 2 bytes (version = 1), 2 bytes channel count, following is repeated for each count: 4 bytes channel ID, Color: 2 bytes for space followed by 4 * 2 byte color component. This resource is not read or used by Photoshop.
  0x042D (Photoshop CS2) Layer Selection ID(s). 2 bytes count, following is repeated for each count: 4 bytes layer ID
  0x042E (Photoshop CS2) HDR Toning information
  0x042F (Photoshop CS2) Print info
  0x0430 (Photoshop CS2) Layer Group(s) Enabled ID. 1 byte for each layer in the document, repeated by length of the resource. NOTE: Layer groups have start and end markers
  0x0431 (Photoshop CS3) Color samplers resource. Also see ID 1038 for old format. See See Color samplers resource format.
  0x0432 (Photoshop CS3) Measurement Scale. 4 bytes (descriptor version = 16), Descriptor (see See Descriptor structure)
  0x0433 (Photoshop CS3) Timeline Information. 4 bytes (descriptor version = 16), Descriptor (see See Descriptor structure)
  0x0434 (Photoshop CS3) Sheet Disclosure. 4 bytes (descriptor version = 16), Descriptor (see See Descriptor structure)
  0x0435 (Photoshop CS3) DisplayInfo structure to support floating point clors. Also see ID 1007. See Appendix A in Photoshop API Guide.pdf .
  0x0436 (Photoshop CS3) Onion Skins. 4 bytes (descriptor version = 16), Descriptor (see See Descriptor structure)
  0x0438 (Photoshop CS4) Count Information. 4 bytes (descriptor version = 16), Descriptor (see See Descriptor structure) Information about the count in the document. See the Count Tool.
  0x043A (Photoshop CS5) Print Information. 4 bytes (descriptor version = 16), Descriptor (see See Descriptor structure) Information about the current print settings in the document. The color management options.
  0x043B (Photoshop CS5) Print Style. 4 bytes (descriptor version = 16), Descriptor (see See Descriptor structure) Information about the current print style in the document. The printing marks, labels, ornaments, etc.
  0x043C (Photoshop CS5) Macintosh NSPrintInfo. Variable OS specific info for Macintosh. NSPrintInfo. It is recommened that you do not interpret or use this data.
  0x043D (Photoshop CS5) Windows DEVMODE. Variable OS specific info for Windows. DEVMODE. It is recommened that you do not interpret or use this data.
  0x043E (Photoshop CS6) Auto Save File Path. Unicode string. It is recommened that you do not interpret or use this data.
  0x043F (Photoshop CS6) Auto Save Format. Unicode string. It is recommened that you do not interpret or use this data.
  0x0440 (Photoshop CC) Path Selection State. 4 bytes (descriptor version = 16), Descriptor (see See Descriptor structure) Information about the current path selection state.
  0x07D0-0x0BB6 Path Information (saved paths). See See Path resource format.
  0x0BB7 Name of clipping path. See See Path resource format.
  0x0BB8 (Photoshop CC) Origin Path Info. 4 bytes (descriptor version = 16), Descriptor (see See Descriptor structure) Information about the origin path data.
  0x0FA0-0x1387 Plug-In resource(s). Resources added by a plug-in. See the plug-in API found in the SDK documentation
  0x1B58 Image Ready variables. XML representation of variables definition
  0x1B59 Image Ready data sets
  0x1F40 (Photoshop CS3) Lightroom workflow, if present the document is in the middle of a Lightroom workflow.
  0x2710 Print flags information. 2 bytes version ( = 1), 1 byte center crop marks, 1 byte ( = 0), 4 bytes bleed width value, 2 bytes bleed width scale.
  */
}
