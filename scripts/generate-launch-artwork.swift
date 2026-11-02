import Foundation
import CoreGraphics

let output = CommandLine.arguments[1]
var box = CGRect(x: 0, y: 0, width: 140, height: 150)
let context = CGContext(URL(fileURLWithPath: output) as CFURL, mediaBox: &box, nil)!
context.beginPDFPage(nil)
context.translateBy(x: 0, y: 150)
context.scaleBy(x: 1, y: -1)
func color(_ rgb: UInt32) -> CGColor { CGColor(red: CGFloat((rgb >> 16) & 255)/255, green: CGFloat((rgb >> 8) & 255)/255, blue: CGFloat(rgb & 255)/255, alpha: 1) }
func ellipse(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ fill: UInt32) { context.setFillColor(color(fill)); context.fillEllipse(in: CGRect(x:x,y:y,width:w,height:h)) }
func rounded(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double, _ fill: UInt32) { context.setFillColor(color(fill)); context.addPath(CGPath(roundedRect:CGRect(x:x,y:y,width:w,height:h),cornerWidth:r,cornerHeight:r,transform:nil));context.fillPath() }
func arm(_ x: Double, _ y: Double, _ pivotX: Double, _ pivotY: Double, _ degrees: Double) { context.saveGState(); context.translateBy(x:pivotX,y:pivotY);context.rotate(by:degrees * .pi / 180);context.translateBy(x:-pivotX,y:-pivotY);rounded(x,y,17,36,8,0xF4BB95);context.restoreGState() }
ellipse(39,123,24,18,0xF4BB95);ellipse(77,123,24,18,0xF4BB95)
arm(32,81,40,85,34);arm(91,80,99,85,-34)
rounded(35,78,71,61,28,0xE6AF67)
ellipse(19,45,16,16,0xF4BB95);ellipse(105,45,16,16,0xF4BB95)
rounded(28,19,84,78,39,0xF4BB95)
context.setStrokeColor(color(0x344C40));context.setLineCap(.round);context.setLineWidth(3.5)
context.move(to:CGPoint(x:62,y:24));context.addCurve(to:CGPoint(x:72,y:8),control1:CGPoint(x:86,y:24),control2:CGPoint(x:86,y:3));context.addCurve(to:CGPoint(x:73,y:14),control1:CGPoint(x:64,y:10),control2:CGPoint(x:66,y:18));context.strokePath()
ellipse(38,63,14,8,0xEA907D);ellipse(88,63,14,8,0xEA907D)
rounded(54,48,5,8,2.5,0x344C40);rounded(81,48,5,8,2.5,0x344C40)
context.setLineWidth(2.5);context.move(to:CGPoint(x:64,y:70));context.addQuadCurve(to:CGPoint(x:77,y:70),control:CGPoint(x:70.5,y:80));context.strokePath()
context.setFillColor(color(0xFFF8ED));context.move(to:CGPoint(x:70,y:114));context.addLine(to:CGPoint(x:62,y:106));context.addCurve(to:CGPoint(x:70,y:101),control1:CGPoint(x:57,y:100),control2:CGPoint(x:66,y:95));context.addCurve(to:CGPoint(x:78,y:106),control1:CGPoint(x:74,y:95),control2:CGPoint(x:83,y:100));context.closePath();context.fillPath()
context.endPDFPage();context.closePDF()
