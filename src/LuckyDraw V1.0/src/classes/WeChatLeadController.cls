public class WeChatLeadController
{
    private static final String aesKey = '3fXiwmRWxTLLNpytB10wUWonU2f8gyGTg1Rm0Q5hI8E=';

    public WeChatLeadController()
    {
        setBannerAndTitle();

        String code = ApexPages.currentPage().getParameters().get('code');
        
        String openId = getOpenId(code, WeChatAccountId);
        EncryedOpenId = encryptOpenId(openId);
    }

    public String EncryedOpenId { get; set; }
    public String BannerURL { get; set; }
    public String Title { get; set; }
    public Boolean IsPrint { get; set; }
    public String WeChatAccountId { get; set; }
    public String SuccessTemplateId { get; set; }
    public String CampaignId { get; set; }
    public String CampaignMemberStatus { get; set; }
    public String SuccessMessageId { get; set; }

    @RemoteAction
    public static String init(String openIdStr, String code, String wechatAccountId, String urlStr)
    {
        String openId = decryptedOpenId(openIdStr);

        // If code is invalid that need to redirect user to WeChat Oauth URL
        if(String.isBlank(openId))
        {
            String url = urlStr.replaceAll('&code=[^\\&]+', '');
            String oauthUrl = getOauthUrl(wechatAccountId, url);
            oauthUrl = (oauthUrl != null) ? oauthUrl : '';
            return '{\"oauth_url\": \"' + oauthUrl + '\"}';
        }
        else
        {
            List<Charket__WeChatFollower__c> followers = [select Charket__Lead__c, Charket__Contact__c
                    from Charket__WeChatFollower__c
                    where Charket__OpenId__c = :openId
                    and (Charket__Lead__c != null or Charket__Contact__c != null)];

            if(followers.size() > 0)
            {
                return getLeadOrContactInfo(followers[0]);
            }
        }
        return null;
    }

    @RemoteAction
    public static String save(String firstNameStr, String lastNameStr, String emailStr, String companyStr, String isInterestedInCharket, String cId,
        String cstatus, String openIdStr, String templateId, String messageId, Boolean isPrint, String wechatAccountId, String qrId)
    {
        String oldLeadId;
        String oldContactId;
        Boolean isRelatedWithEmail;
        Charket__WeChatFollower__c currentFollower;

        String openId = decryptedOpenId(openIdStr);

        List<Charket__WeChatFollower__c> followers = [select Charket__Lead__c, Charket__Contact__c,
                Charket__Lead__r.Email, Charket__Contact__r.Email
                from Charket__WeChatFollower__c
                where Charket__OpenId__c = :openId and Charket__OpenId__c != null];

        if(followers.size() > 0)
        {
            currentFollower = followers[0];
            oldLeadId = currentFollower.Charket__Lead__c;
            oldContactId = currentFollower.Charket__Contact__c;
            isRelatedWithEmail = (String.isNotBlank(oldLeadId) && String.isNotBlank(currentFollower.Charket__Lead__r.Email))
                    || (String.isNotBlank(oldContactId) && String.isNotBlank(currentFollower.Charket__Contact__r.Email));
        }

        if(currentFollower != null)
        {
            String leadOrContactId = updateRelatedLeadOrContact(isRelatedWithEmail, oldContactId, oldLeadId,
                    firstNameStr, lastNameStr, emailStr, companyStr, isInterestedInCharket);

            String contactId = (Id.valueOf(leadOrContactId).getSObjectType() == Contact.sObjectType)
                    ? leadOrContactId : null;
            String leadId = (contactId == null) ? leadOrContactId : null;
            currentFollower.Charket__Contact__c = contactId;
            currentFollower.Charket__Lead__c = leadId;
            update currentFollower;
            
            String badgeName = containsChineseCharacters(firstNameStr) && containsChineseCharacters(lastNameStr)
                ? (lastNameStr + firstNameStr) : (firstNameStr + ' ' + lastNameStr);

            updateCampaignMemberStatus(leadId, contactId, cId, cstatus, templateId, messageId);
            updateFollowerPrintFields(isPrint, currentFollower.Id, badgeName, companyStr, qrId);
        }

        return null;
    }

    private static String updateRelatedLeadOrContact(Boolean isRelatedWithEmail, String contactId, String leadId,
                String firstNameStr, String lastNameStr, String emailStr, String companyStr, String isInterestedInCharket)
    {
        if(!isRelatedWithEmail && String.isNotBlank(emailStr))
        {
            List<Contact> contacts = [select Id, AccountId from Contact where Email = :emailStr limit 1];
            if(contacts.size() > 0)
            {
                if(leadId != null)
                {
                    Database.LeadConvert lc = new Database.LeadConvert();
                    lc.setLeadId(leadId);
                    lc.setContactId(contacts[0].Id);
                    lc.setAccountId(contacts[0].AccountId);
                    lc.setDoNotCreateOpportunity(true);
                    LeadStatus convertStatus = [select MasterLabel from LeadStatus where IsConverted = true limit 1];
                    lc.setConvertedStatus(convertStatus.MasterLabel);
                    Database.LeadConvertResult lcr = Database.convertLead(lc);
                }
                if(contactId != null)
                {
                    Contact oldContact = new Contact(Id = contactId);
                    merge contacts[0] oldContact;
                }
                contactId = contacts[0].Id;
                leadId = null;
            }
            else
            {
                List<Lead> leads = [select Id from Lead where Email = :emailStr and IsConverted = false limit 1];
                if(leads.size() > 0)
                {
                    if(leadId != null)
                    {
                        Lead oldLead = new Lead(Id = leadId);
                        merge leads[0] oldLead;
                    }
                    leadId = leads[0].Id;
                    contactId = null;
                }
            }
        }

        if(String.isNotBlank(contactId))
        {
            contactId = updateContact(contactId, firstNameStr, lastNameStr, emailStr, isInterestedInCharket);
        }
        else // Insert or update lead
        {
            leadId = saveLead(leadId, firstNameStr, lastNameStr, emailStr, companyStr, isInterestedInCharket);
        }

        return String.isNotBlank(contactId) ? contactId : leadId;
    }

    private static String getOpenId(String wechatCode, String wechatAccountId)
    {
        if(!Test.isRunningTest())
        {
            try
            {
                if(String.isNotBlank(wechatCode) && String.isNotBlank(wechatAccountId))
                {
                    Charket.WeChatClient client = new Charket.WeChatClient(wechatAccountId);
                    Charket.WeChatApiOAuth oauth = client.getOAuth();

                    Charket.WeChatApiOAuth.AuthTokenResponse response = oauth.handleCallback(wechatCode, '');
                    return response.OpenId;
                }
            }
            catch(Exception ex) {}
        }
        else
        {
            return 'OPENID';
        }

        return null;
    }

    private void setBannerAndTitle()
    {
        String qrCodeId = ApexPages.currentPage().getParameters().get('qrId');

        if(String.isNotBlank(qrCodeId))
        {

            List<Charket__WeChatQRCode__c> qrCodes = [select MoreInfo__c, 
                    Charket__WeChatAccount__c, Charket__WhatId__c
                    from Charket__WeChatQRCode__c where Id = :qrCodeId limit 1];
            if(qrCodes.size() > 0 && String.isNotBlank(qrCodes[0].MoreInfo__c))
            {
                CampaignId = qrCodes[0].Charket__WhatId__c;
                WeChatAccountId = qrCodes[0].Charket__WeChatAccount__c;

                Map<String, Object> moreInfo = (Map<String, Object>) JSON.deserializeUntyped(qrCodes[0].MoreInfo__c);
                BannerURL = (String)moreInfo.get('FormBanner');
                Title = (String)moreInfo.get('FormTitle');
                IsPrint = (Boolean)moreInfo.get('IsPrint');
                SuccessMessageId = (String)moreInfo.get('MessageId');
                SuccessTemplateId = (String)moreInfo.get('TemplateId');
                CampaignMemberStatus = (String)moreInfo.get('CampaignMemberStatus');
            }
        }
        if(String.isBlank(WeChatAccountId) || String.isBlank(CampaignId))
        {
            WeChatAccountId = ApexPages.currentPage().getParameters().get('accId');
            SuccessTemplateId = ApexPages.currentPage().getParameters().get('templateId');
            CampaignId = ApexPages.currentPage().getParameters().get('cId');
            CampaignMemberStatus = ApexPages.currentPage().getParameters().get('cstatus');
        }
        if(String.isBlank(Title))
        {
            Title = 'Charket';
        }
        
        if(String.isBlank(BannerURL))
        {
            BannerURL = 'https://asset.charket.com.cn/assets/image/charket/banner.jpeg';
        }
    }

    private static String getLeadOrContactInfo(Charket__WeChatFollower__c follower)
    {
        if(String.isNotBlank(follower.Charket__Contact__c))
        {
            List<Contact> contacts = [select Name, FirstName, LastName, Department,
                    Title, Email, Phone, Account.Name, IsInterestedInCharket__c
                    from Contact where Id = :follower.Charket__Contact__c];

            return '{\"contact\": ' + JSON.serialize(contacts[0]) + '}';
        }
        else
        {
            List<Lead> leads = [select Name, FirstName, LastName, Email, Company, IsInterestedInCharket__c
                    from Lead where Id = :follower.Charket__Lead__c];

            return '{\"lead\": ' + JSON.serialize(leads[0]) + '}';
        }

        return null;
    }

    private static String saveLead(Id leadId, String firstNameStr, String lastNameStr,
        String emailStr, String companyStr, String isInterestedInCharket)
    {
        Lead lead = new Lead(Id = leadId);
        lead.FirstName = firstNameStr;
        lead.LastName = lastNameStr;
        lead.Email = emailStr;
        lead.Company = companyStr;
        lead.LeadSource = 'WeChat';
        lead.IsInterestedInCharket__c = (isInterestedInCharket == '1');

        upsert lead;
        return lead.Id;
    }

    private static String updateContact(Id contactId, String firstNameStr, String lastNameStr,
        String emailStr, String isInterestedInCharket)
    {
        Contact contact = new Contact(Id = contactId);
        contact.FirstName = firstNameStr;
        contact.LastName = lastNameStr;
        contact.Email = emailStr;
        contact.IsInterestedInCharket__c = (isInterestedInCharket == '1');

        update contact;
        return contact.Id;
    }

    private static void updateCampaignMemberStatus(String leadId, String contactId, String campaignId, String status, String templateId, String messageId)
    {
        if(String.isBlank(campaignId))
        {
            return;
        }
        CampaignMember member;

        List<CampaignMember> members = [select Id from CampaignMember
                where CampaignId = :campaignId and
                 ((LeadId = :leadId and LeadId != null) or (ContactId = :contactId and ContactId != null))];

        if(members.size() > 0)
        {
            member = members[0];
            member.Status = (String.isNotBlank(status)) ? status : 'Responded';
            update member;
        }
        else if(String.isNotBlank(status))
        {
            member = new CampaignMember(CampaignId = campaignId, LeadId = leadId,
                    ContactId = contactId, Status = status);
            insert member;
        }

        String leadOrContactId = String.isNotBlank(leadId) ? leadId : contactId;

        sendTemplateNotification(member.Id, templateId, messageId, leadOrContactId);
    }

    public static void sendTemplateNotification(String memberId, String templateId, String messageId, String leadOrContactId)
    {
        if(String.isNotBlank(memberId) && String.isNotBlank(templateId) && String.isNotBlank(leadOrContactId))
        {
            Charket.CharketSendWeChatNotificationAction.SendTemplateNotificationRequest templateRequest = new Charket.CharketSendWeChatNotificationAction.SendTemplateNotificationRequest();
            templateRequest.objectId = memberId;
            templateRequest.templateId = templateId;
            templateRequest.whoId = leadOrContactId;
            List<Charket.CharketSendWeChatNotificationAction.SendTemplateNotificationRequest> templateRequests = new List<Charket.CharketSendWeChatNotificationAction.SendTemplateNotificationRequest>();
            templateRequests.add(templateRequest);
            Charket.CharketSendWeChatNotificationAction.sendTemplateNotification(templateRequests);
        }
        if(String.isNotBlank(memberId) && String.isNotBlank(messageId) && String.isNotBlank(leadOrContactId))
        {
            Charket.CharketSendWeChatMessageAction.SendWeChatMessageRequest messageRequest = new Charket.CharketSendWeChatMessageAction.SendWeChatMessageRequest();
            messageRequest.objectId = memberId;
            messageRequest.messageId = messageId;
            messageRequest.whoId = leadOrContactId;
            List<Charket.CharketSendWeChatMessageAction.SendWeChatMessageRequest> messageRequests = new List<Charket.CharketSendWeChatMessageAction.SendWeChatMessageRequest>();
            messageRequests.add(messageRequest);
            Charket.CharketSendWeChatMessageAction.sendWeChatMessage(messageRequests);
        }
    }
    
    public static void updateFollowerPrintFields(Boolean isPrint, String followerId, String badgeName, String badgeCompany, String qrId)
    {
        if(isPrint && String.isNotBlank(followerId))
        {
            if(String.isBlank(qrId))
            {
                List<Charket__WeChatEvent__c> events = [select Charket__WeChatQRCode__c
                        from Charket__WeChatEvent__c
                        where Charket__Type__c = 'Scan'
                        and Charket__WeChatFollower__c = :followerId order by CreatedDate desc limit 1];
                if(events.size() > 0)
                {
                    qrId = events[0].Charket__WeChatQRCode__c;
                }
            }
            Charket__WeChatFollower__c follower = new Charket__WeChatFollower__c(Id = followerId);
            follower.BadgeId__c = qrId;
            follower.BadgeName__c = badgeName;
            follower.BadgeCompany__c = badgeCompany;
            follower.BadgePrintDate__c = Datetime.now();
            update follower;
        }
    }
    
    
    private static String getOauthUrl(String wechatAccountId, String url)
    {
        String result;

        try
        {
            String siteUrl = url;
            Charket.WeChatApiOAuth oauth = (new Charket.WeChatClient(wechatAccountId)).getOAuth();
            result = oauth.initiate(siteUrl, Charket.WeChatApiOAuth.Scope.base, '').getUrl();
        }
        catch(Exception ex) {}

        return result;
    }


    private static String encryptOpenId(String openId)
    {
        if(String.isNotBlank(openId))
        {
            Blob key = EncodingUtil.base64Decode(aesKey);
            Blob data = Blob.valueOf(openId);
            Blob encrypted = Crypto.encryptWithManagedIV('AES256', key, data);

            return EncodingUtil.base64Encode(encrypted);
        }

        return null;
    }

    private static String decryptedOpenId(String encryptedOpenId)
    {
        if(String.isNotBlank(encryptedOpenId))
        {
            Blob key = EncodingUtil.base64Decode(aesKey);
            Blob data = EncodingUtil.base64Decode(encryptedOpenId);
            Blob decrypted = Crypto.decryptWithManagedIV('AES256', key, data);

            return decrypted.toString();
        }

        return null;
    }
    
    public static Boolean containsChineseCharacters(String InputString){
        Pattern p = Pattern.compile('\\p{IsHan}');
        Matcher m = p.matcher(InputString);
        return m.find();
    }

}